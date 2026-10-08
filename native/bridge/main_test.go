package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/juicedata/juicefs/pkg/meta"
	"github.com/juicedata/juicefs/pkg/vfs"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
)

func fixture(t *testing.T) (*engine, config) {
	t.Helper()
	root := t.TempDir()
	c := config{MetadataURL: "sqlite3://" + filepath.Join(root, "metadata.db"), LocalObjectDirectory: filepath.Join(root, "objects"), CreateLocal: true}
	e, err := connect(c)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = e.fs.Close() })
	c.CreateLocal = false
	return e, c
}
func write(t *testing.T, e *engine, p, version, operation string, data []byte) *entry {
	t.Helper()
	result, err := e.commit(request{Path: p, ExpectedVersion: version, OperationID: operation, Size: int64(len(data)), BaseVisibleSize: int64(len(data)), Mode: 0644, Patches: []patch{{Data: data, Length: int64(len(data))}}})
	if err != nil {
		t.Fatal(err)
	}
	return result
}
func read(t *testing.T, e *engine, p string, offset int64, length int) []byte {
	t.Helper()
	f, code := e.fs.Open(e.ctx, p, vfs.MODE_MASK_R)
	if code != 0 {
		t.Fatal(code)
	}
	defer f.Close(e.ctx)
	buf := make([]byte, length)
	n, err := f.Pread(e.ctx, buf, offset)
	if err != nil {
		t.Fatal(err)
	}
	return buf[:n]
}
func TestMetadataExportsRecordedAccessTime(t *testing.T) {
	e, _ := fixture(t)
	st, code := e.fs.Stat(e.ctx, "/")
	if code != 0 {
		t.Fatal(code)
	}
	// The serializer must preserve atime, not silently substitute mtime.
	st.Attr().Atime = 200000000
	st.Attr().Atimensec = 123456789
	st.Attr().Mtime = 400000000
	data, err := json.Marshal(info("/", st))
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]json.RawMessage
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if string(got["accessedNanoseconds"]) != "200000000123456789" {
		t.Fatalf("recorded access time missing or altered: %s", got["accessedNanoseconds"])
	}
}
func TestSparseRangesAndMetadataOnlyListing(t *testing.T) {
	e, c := fixture(t)
	payload := bytes.Repeat([]byte("abcdefghijklmnop"), 65536)
	result, err := e.commit(request{Path: "/movie.bin", OperationID: "large", Size: 64 << 20, BaseVisibleSize: 0, Mode: 0644, Patches: []patch{{Offset: 0, Data: payload, Length: int64(len(payload))}, {Offset: 60 << 20, Data: payload, Length: int64(len(payload))}}})
	if err != nil {
		t.Fatal(err)
	}
	if result.Size != 64<<20 {
		t.Fatal(result)
	}
	cold, err := connect(c)
	if err != nil {
		t.Fatal(err)
	}
	defer cold.fs.Close()
	before := cold.storage.bytes.Load()
	if _, err := cold.stat("/movie.bin"); err != nil {
		t.Fatal(err)
	}
	if cold.storage.bytes.Load() != before {
		t.Fatal("metadata fetched content")
	}
	if got := read(t, cold, "/movie.bin", 60<<20, 4096); !bytes.Equal(got, payload[:4096]) {
		t.Fatal("distant range differs")
	}
	transferred := cold.storage.bytes.Load() - before
	if transferred <= 0 || transferred >= result.Size {
		t.Fatalf("expected partial fetch, got %d / %d", transferred, result.Size)
	}
	t.Logf("64 MiB logical file, 4 KiB distant read, %d actual object bytes", transferred)
}
func TestCommitConflictReplayAndReopen(t *testing.T) {
	e, c := fixture(t)
	first := write(t, e, "/file", "", "first", []byte("abcdef"))
	next := write(t, e, "/file", first.Version, "second", []byte("uvwxyz"))
	replay := write(t, e, "/file", first.Version, "second", []byte("uvwxyz"))
	if replay.Version != next.Version {
		t.Fatal("replay changed version")
	}
	_, err := e.commit(request{Path: "/file", ExpectedVersion: first.Version, OperationID: "stale", Size: 6, BaseVisibleSize: 6})
	if !errors.Is(err, syscall.ESTALE) {
		t.Fatalf("stale update accepted: %v", err)
	}
	_, err = e.commit(request{Path: "/file", OperationID: "create-existing", Size: 0})
	if !errors.Is(err, syscall.ESTALE) {
		t.Fatalf("create clobbered existing: %v", err)
	}
	reopened, err := connect(c)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.fs.Close()
	if got := read(t, reopened, "/file", 0, 6); string(got) != "uvwxyz" {
		t.Fatalf("reopened content: %q", got)
	}
}
func TestShrinkThenExtendClearsTail(t *testing.T) {
	e, _ := fixture(t)
	first := write(t, e, "/file", "", "base", []byte("0123456789"))
	_, err := e.commit(request{Path: "/file", ExpectedVersion: first.Version, OperationID: "truncate", Size: 10, BaseVisibleSize: 3})
	if err != nil {
		t.Fatal(err)
	}
	if got := read(t, e, "/file", 0, 10); !bytes.Equal(got, []byte{'0', '1', '2', 0, 0, 0, 0, 0, 0, 0}) {
		t.Fatalf("old bytes resurrected: %q", got)
	}
}
func TestFailedStageLeavesOriginalAndRetryWorks(t *testing.T) {
	e, _ := fixture(t)
	first := write(t, e, "/file", "", "first", []byte("original"))
	r := request{Path: "/file", ExpectedVersion: first.Version, OperationID: "recover", Size: 8, BaseVisibleSize: 8, Patches: []patch{{LocalFile: filepath.Join(t.TempDir(), "missing"), Length: 8}}}
	if _, err := e.commit(r); err == nil {
		t.Fatal("missing patch unexpectedly committed")
	}
	if got := read(t, e, "/file", 0, 8); string(got) != "original" {
		t.Fatalf("failure changed destination: %q", got)
	}
	r.Patches = []patch{{Data: []byte("replaced"), Length: 8}}
	if _, err := e.commit(r); err != nil {
		t.Fatal(err)
	}
}
func TestCooperativeClientsSerializeConflicts(t *testing.T) {
	e, c := fixture(t)
	first := write(t, e, "/file", "", "first", []byte("original"))
	other, err := connect(c)
	if err != nil {
		t.Fatal(err)
	}
	defer other.fs.Close()
	var group sync.WaitGroup
	results := make(chan error, 2)
	for i, client := range []*engine{e, other} {
		group.Add(1)
		go func(index int, client *engine) {
			defer group.Done()
			_, err := client.commit(request{Path: "/file", ExpectedVersion: first.Version, OperationID: []string{"one", "two"}[index], Size: 8, BaseVisibleSize: 8, Patches: []patch{{Data: []byte("newbytes"), Length: 8}}})
			results <- err
		}(i, client)
	}
	group.Wait()
	close(results)
	success, conflict := 0, 0
	for err := range results {
		if err == nil {
			success++
		} else if errors.Is(err, syscall.ESTALE) {
			conflict++
		} else {
			t.Fatal(err)
		}
	}
	if success != 1 || conflict != 1 {
		t.Fatalf("success=%d conflict=%d", success, conflict)
	}
}
func TestLocalExtentLengthIsRespected(t *testing.T) {
	e, _ := fixture(t)
	blob := filepath.Join(t.TempDir(), "extent")
	if err := os.WriteFile(blob, []byte("abcdefgh"), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := e.commit(request{Path: "/file", OperationID: "extent", Size: 3, Mode: 0644, Patches: []patch{{LocalFile: blob, Length: 3}}})
	if err != nil {
		t.Fatal(err)
	}
	if got := read(t, e, "/file", 0, 3); string(got) != "abc" {
		t.Fatalf("extent contents: %q", got)
	}
}
func TestReservedPaths(t *testing.T) {
	for _, p := range []string{"/.streamdrive", "/.streamdrive/lock", "/a/../.streamdrive/lock", "relative", "/a\x00b"} {
		if _, err := normalized(p); err == nil {
			t.Fatalf("accepted reserved path %q", p)
		}
	}
}
func TestBadConfigurationReturnsErrorInsteadOfExiting(t *testing.T) {
	for _, uri := range []string{"bad", "invalid-driver://address", "redis://%broken"} {
		if _, err := connect(config{MetadataURL: uri}); err == nil {
			t.Fatalf("accepted invalid URI %q", uri)
		}
	}
}
func TestSymlinkCannotAliasReservedControlFiles(t *testing.T) {
	e, _ := fixture(t)
	if code := e.fs.Symlink(e.ctx, internalRoot, "/alias"); code != 0 {
		t.Fatal(code)
	}
	if err := e.checkPublicPath("/alias/lock"); !errors.Is(err, syscall.ENOTSUP) {
		t.Fatalf("symlink accepted: %v", err)
	}
}
func TestMetadataAndObjectBackupRestore(t *testing.T) {
	e, c := fixture(t)
	payload := bytes.Repeat([]byte("backup-data"), 8192)
	write(t, e, "/preserved", "", "backup", payload)
	var snapshot bytes.Buffer
	if err := e.meta.DumpMeta(&snapshot, meta.RootInode, 1, true, false, true); err != nil {
		t.Fatal(err)
	}
	restoreRoot := t.TempDir()
	restoredObjects := filepath.Join(restoreRoot, "objects")
	if err := filepath.WalkDir(c.LocalObjectDirectory, func(source string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(c.LocalObjectDirectory, source)
		if err != nil {
			return err
		}
		destination := filepath.Join(restoredObjects, relative)
		if item.IsDir() {
			return os.MkdirAll(destination, 0700)
		}
		data, err := os.ReadFile(source)
		if err != nil {
			return err
		}
		return os.WriteFile(destination, data, 0600)
	}); err != nil {
		t.Fatal(err)
	}
	restoredURL := "sqlite3://" + filepath.Join(restoreRoot, "metadata.db")
	restoredMeta, err := meta.NewStreamDriveClient(restoredURL, meta.DefaultConf())
	if err != nil {
		t.Fatal(err)
	}
	if err := restoredMeta.LoadMeta(&snapshot); err != nil {
		t.Fatal(err)
	}
	format, err := restoredMeta.Load(true)
	if err != nil {
		t.Fatal(err)
	}
	format.Bucket = restoredObjects + "/"
	if err := restoredMeta.Init(format, false); err != nil {
		t.Fatal(err)
	}
	recovered, err := connect(config{MetadataURL: restoredURL})
	if err != nil {
		t.Fatal(err)
	}
	defer recovered.fs.Close()
	if got := read(t, recovered, "/preserved", 0, len(payload)); !bytes.Equal(got, payload) {
		t.Fatal("restored metadata+objects changed content")
	}
}

func TestRenameReplacesExistingFileAtomically(t *testing.T) {
	e, _ := fixture(t)
	write(t, e, "/source", "", "source", []byte("replacement"))
	write(t, e, "/destination", "", "destination", []byte("old"))
	engines.Lock()
	engines.next++
	id := engines.next
	engines.values[id] = e
	engines.Unlock()
	defer func() { engines.Lock(); delete(engines.values, id); engines.Unlock() }()
	response := dispatch(request{Op: "rename", Handle: id, Path: "/source", Destination: "/destination"})
	if !response.OK {
		t.Fatalf("rename-over-existing failed: %s", response.Error)
	}
	if got := read(t, e, "/destination", 0, 11); string(got) != "replacement" {
		t.Fatalf("destination is %q", got)
	}
	if _, err := e.stat("/source"); !errors.Is(err, syscall.ENOENT) {
		t.Fatalf("source still exists: %v", err)
	}
}

func TestRenameTypeErrorPreservesBothEntries(t *testing.T) {
	e, _ := fixture(t)
	write(t, e, "/source", "", "source", []byte("preserved"))
	if code := e.fs.Mkdir(e.ctx, "/directory", 0755, 0022); code != 0 {
		t.Fatal(code)
	}
	engines.Lock()
	engines.next++
	id := engines.next
	engines.values[id] = e
	engines.Unlock()
	defer func() { engines.Lock(); delete(engines.values, id); engines.Unlock() }()
	response := dispatch(request{Op: "rename", Handle: id, Path: "/source", Destination: "/directory"})
	if response.OK {
		t.Fatal("file replaced directory")
	}
	if got := read(t, e, "/source", 0, 9); string(got) != "preserved" {
		t.Fatalf("source changed: %q", got)
	}
	st, err := e.stat("/directory")
	if err != nil || st.Kind != "directory" {
		t.Fatalf("destination changed: %v %v", st, err)
	}
}

func TestVolumeIdentitySurvivesReconnectAndDiffersAcrossVolumes(t *testing.T) {
	e, c := fixture(t)
	reopened, err := connect(c)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.fs.Close()
	other, _ := fixture(t)
	identity := e.meta.GetFormat().UUID
	if identity == "" || identity != reopened.meta.GetFormat().UUID {
		t.Fatal("volume identity is not stable")
	}
	if identity == other.meta.GetFormat().UUID {
		t.Fatal("distinct volumes shared identity")
	}
	engines.Lock()
	engines.next++
	id := engines.next
	engines.values[id] = e
	engines.Unlock()
	defer func() { engines.Lock(); delete(engines.values, id); engines.Unlock() }()
	response := dispatch(request{Op: "identity", Handle: id})
	if !response.OK || response.VolumeIdentity != identity {
		t.Fatalf("identity ABI failed: %+v", response)
	}
}

func TestFailedConnectClosesMetadataSession(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("permission denial requires an unprivileged fixture owner")
	}
	e, c := fixture(t)
	before, err := e.meta.ListSessions()
	if err != nil {
		t.Fatal(err)
	}
	if code := e.fs.Unlink(e.ctx, internalRoot+"/lock"); code != 0 {
		t.Fatal(code)
	}
	dir, code := e.fs.Open(e.ctx, internalRoot, 0)
	if code != 0 {
		t.Fatal(code)
	}
	defer dir.Close(e.ctx)
	if code := dir.Chmod(e.ctx, 0500); code != 0 {
		t.Fatal(code)
	}
	defer dir.Chmod(e.ctx, 0700)
	for i := 0; i < 3; i++ {
		failed, err := connect(c)
		if failed != nil {
			_ = failed.fs.Close()
			t.Fatal("connect unexpectedly succeeded without writable control directory")
		}
		if !errors.Is(err, syscall.EACCES) {
			t.Fatalf("expected control-lock creation EACCES, got %v", err)
		}
		after, err := e.meta.ListSessions()
		if err != nil {
			t.Fatal(err)
		}
		if len(after) != len(before) {
			t.Fatalf("failed connect leaked metadata session: before %d, after %d", len(before), len(after))
		}
	}
}

func TestS3TestInitializationIsFreshAndCredentialsStayInMemory(t *testing.T) {
	endpoint := "https://127.0.0.1:1" // No live server or external target is required.
	root := t.TempDir()
	file := filepath.Join(root, "metadata.sqlite3")
	payload := map[string]interface{}{"metadataURL": "sqlite3://" + file, "createS3Test": true, "s3BucketURL": endpoint + "/isolated-test", "objectCredentials": map[string]string{"accessKey": "test-access-only-in-memory", "secretKey": "test-secret-only-in-memory", "sessionToken": "test-session-only-in-memory"}}
	encoded, _ := json.Marshal(payload)
	var c config
	if err := json.Unmarshal(encoded, &c); err != nil {
		t.Fatal(err)
	}
	e, err := connect(c)
	if err != nil {
		t.Fatalf("fresh S3 test metadata initialization failed: %v", err)
	}
	defer e.fs.Close()
	format := e.meta.GetFormat()
	if format.Storage != "s3" || !strings.HasPrefix(format.Name, "streamdrive-smoke-") || format.Bucket != endpoint+"/isolated-test" {
		t.Fatal("unexpected nonsecret S3 format")
	}
	if format.AccessKey != "" || format.SecretKey != "" || format.SessionToken != "" {
		t.Fatal("credentials persisted in format")
	}
	if _, err := connect(c); !errors.Is(err, syscall.EEXIST) {
		t.Fatal("reinitialization did not reject existing metadata")
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		data, err := os.ReadFile(filepath.Join(root, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		for _, secret := range []string{"test-access-only-in-memory", "test-secret-only-in-memory", "test-session-only-in-memory"} {
			if bytes.Contains(data, []byte(secret)) {
				t.Fatal("credential bytes found in metadata artifacts")
			}
		}
	}
	if e.storage.gets.Load() != 0 {
		t.Fatal("initialization accessed object storage")
	}
	// Isolate the test from any operator AWS provider configuration.
	for _, name := range []string{"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE"} {
		t.Setenv(name, "")
	}
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", filepath.Join(root, "unused-credentials"))
	t.Setenv("AWS_CONFIG_FILE", filepath.Join(root, "unused-config"))
	c.CreateS3Test = false
	c.ObjectCredentials = nil
	if unexpected, err := connect(c); !errors.Is(err, syscall.EINVAL) {
		if unexpected != nil {
			_ = unexpected.fs.Close()
		}
		t.Fatal("S3 connected without explicit per-connection credentials")
	}
}

func TestS3InitializationRejectsUnsafeTargetsBeforeCreatingMetadata(t *testing.T) {
	for _, target := range []string{"http://example.invalid/bucket", "https://user:private@example.invalid/bucket", "https://example.invalid/bucket?secret=private", "https://example.invalid/bucket/nested", "https://example.invalid/"} {
		file := filepath.Join(t.TempDir(), "metadata.sqlite3")
		encoded, _ := json.Marshal(map[string]interface{}{"metadataURL": "sqlite3://" + file, "createS3Test": true, "s3BucketURL": target, "objectCredentials": map[string]string{"accessKey": "key", "secretKey": "secret"}})
		var c config
		_ = json.Unmarshal(encoded, &c)
		if e, err := connect(c); err == nil {
			_ = e.fs.Close()
			t.Fatal("unsafe S3 initialization succeeded")
		}
		if _, err := os.Stat(file); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("unsafe initialization touched metadata")
		}
	}
}

func TestABIErrorsNeverIncludeRawProviderMessages(t *testing.T) {
	result := errResponse(fmt.Errorf("provider rejected https://private-user:private-password@example.invalid"))
	if strings.Contains(result.Error, "private-") || strings.Contains(result.Error, "example.invalid") {
		t.Fatal("ABI exposed provider secrets")
	}
}
