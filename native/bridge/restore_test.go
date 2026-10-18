package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// backedUp is a drive with one file and one index backup, registered for dispatch.
func backedUp(t *testing.T) (*engine, config, string, []byte) {
	t.Helper()
	e, c := fixture(t)
	payload := bytes.Repeat([]byte("restored"), 4096)
	write(t, e, "/kept", "", "restore", payload)
	engines.Lock()
	engines.next++
	id := engines.next
	engines.values[id] = e
	engines.Unlock()
	t.Cleanup(func() { engines.Lock(); delete(engines.values, id); engines.Unlock() })
	backup := dispatch(request{Op: "backupMeta", Handle: id})
	if !backup.OK {
		t.Fatalf("backupMeta failed: %s", backup.Error)
	}
	return e, c, backup.BackupKey, payload
}

func restoreRequest(bucket, metadata, volume string) request {
	return request{Op: "restoreMeta", Config: config{MetadataURL: "sqlite3://" + metadata, LocalObjectDirectory: bucket, VolumeName: volume}}
}

func expectErrno(t *testing.T, response response, code syscall.Errno) {
	t.Helper()
	if response.OK || response.Errno != int(code) {
		t.Fatalf("expected errno %d, got %+v", code, response)
	}
}

func TestRestoreLoadsTheNewestBackupIntoANewIndex(t *testing.T) {
	e, c, key, payload := backedUp(t)
	metadata := filepath.Join(t.TempDir(), "restored.db")
	restored := dispatch(restoreRequest(c.LocalObjectDirectory, metadata, e.meta.GetFormat().Name))
	if !restored.OK {
		t.Fatalf("restoreMeta failed: %s", restored.Error)
	}
	if restored.BackupKey != key || restored.VolumeIdentity != e.meta.GetFormat().UUID {
		t.Fatalf("restored %q of %q, want %q of %q", restored.BackupKey, restored.VolumeIdentity, key, e.meta.GetFormat().UUID)
	}
	recovered, err := connect(config{MetadataURL: "sqlite3://" + metadata})
	if err != nil {
		t.Fatal(err)
	}
	defer recovered.fs.Close()
	if got := read(t, recovered, "/kept", 0, len(payload)); !bytes.Equal(got, payload) {
		t.Fatal("the restored drive changed content")
	}
}

// Backups made before meta/latest existed are found by listing.
func TestRestoreFindsADumpWithoutThePointer(t *testing.T) {
	e, c, key, _ := backedUp(t)
	if err := os.Remove(filepath.Join(c.LocalObjectDirectory, e.meta.GetFormat().Name, "meta", "latest")); err != nil {
		t.Fatal(err)
	}
	restored := dispatch(restoreRequest(c.LocalObjectDirectory, filepath.Join(t.TempDir(), "restored.db"), e.meta.GetFormat().Name))
	if !restored.OK || restored.BackupKey != key {
		t.Fatalf("restore without pointer: %+v", restored)
	}
}

func TestRestoreNeverReusesAnIndexAndCleansUpAfterFailures(t *testing.T) {
	e, c, _, _ := backedUp(t)
	volume := e.meta.GetFormat().Name
	existing := filepath.Join(t.TempDir(), "existing.db")
	if err := os.WriteFile(existing, []byte("another drive"), 0600); err != nil {
		t.Fatal(err)
	}
	expectErrno(t, dispatch(restoreRequest(c.LocalObjectDirectory, existing, volume)), syscall.EEXIST)
	if data, _ := os.ReadFile(existing); string(data) != "another drive" {
		t.Fatal("an existing index was touched")
	}
	// No such drive: nothing is left behind.
	missing := filepath.Join(t.TempDir(), "missing.db")
	expectErrno(t, dispatch(restoreRequest(c.LocalObjectDirectory, missing, "no-such-drive")), syscall.ENOENT)
	if _, err := os.Stat(missing); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a failed restore left its index file: %v", err)
	}
	expectErrno(t, dispatch(restoreRequest(c.LocalObjectDirectory, missing, "Not A Volume")), syscall.EINVAL)
}

// A dump copied into another bucket describes the first bucket, so it is refused.
func TestRestoreRefusesADumpFromAnotherBucket(t *testing.T) {
	e, c, _, _ := backedUp(t)
	other := t.TempDir()
	source := filepath.Join(c.LocalObjectDirectory, e.meta.GetFormat().Name)
	if err := filepath.Walk(source, func(file string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		relative, _ := filepath.Rel(c.LocalObjectDirectory, file)
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(other, relative), 0700)
		}
		data, err := os.ReadFile(file)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(other, relative), data, 0600)
	}); err != nil {
		t.Fatal(err)
	}
	metadata := filepath.Join(t.TempDir(), "restored.db")
	expectErrno(t, dispatch(restoreRequest(other, metadata, e.meta.GetFormat().Name)), syscall.EXDEV)
	if _, err := os.Stat(metadata); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused restore left its index file: %v", err)
	}
}

func TestListDrivesFindsBackedUpVolumes(t *testing.T) {
	e, c, key, _ := backedUp(t)
	if err := os.MkdirAll(filepath.Join(c.LocalObjectDirectory, "plain-folder"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(c.LocalObjectDirectory, "plain-folder", "photo.jpg"), []byte("not a drive"), 0600); err != nil {
		t.Fatal(err)
	}
	listed := dispatch(request{Op: "listDrives", Config: config{LocalObjectDirectory: c.LocalObjectDirectory}})
	if !listed.OK {
		t.Fatalf("listDrives failed: %s", listed.Error)
	}
	if len(listed.Drives) != 1 || listed.Drives[0].Volume != e.meta.GetFormat().Name || listed.Drives[0].LatestBackup != key {
		t.Fatalf("listed %+v", listed.Drives)
	}
}
