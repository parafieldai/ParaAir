// StreamDrive's deliberately small ABI over the pinned JuiceFS engine.
// JuiceFS is Apache-2.0 licensed; see native/README.md for the exact revision.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/juicedata/juicefs/pkg/chunk"
	"github.com/juicedata/juicefs/pkg/fs"
	"github.com/juicedata/juicefs/pkg/meta"
	"github.com/juicedata/juicefs/pkg/object"
	"github.com/juicedata/juicefs/pkg/utils"
	"github.com/juicedata/juicefs/pkg/vfs"
	"github.com/sirupsen/logrus"
)

const internalRoot = "/.streamdrive"
const revision = "adcca1cc61bb4d668a945d64b2e176b44ac8e5b5"
const maxRead = 8 << 20

// Runtime-only credentials are deliberately separate from the persisted format.
type objectCredentials struct {
	AccessKey    string `json:"accessKey"`
	SecretKey    string `json:"secretKey"`
	SessionToken string `json:"sessionToken,omitempty"`
}
type config struct {
	MetadataURL          string              `json:"metadataURL"`
	CacheDirectory       string              `json:"cacheDirectory"`
	CacheBytes           int64               `json:"cacheBytes"`
	MemoryMiB            int64               `json:"memoryMiB"`
	LocalObjectDirectory string              `json:"localObjectDirectory,omitempty"`
	CreateLocal          bool                `json:"createLocal,omitempty"`
	CreateS3Test         bool                `json:"createS3Test,omitempty"`
	CreateCloudflareTest bool                `json:"createCloudflareTest,omitempty"`
	S3BucketURL          string              `json:"s3BucketURL,omitempty"`
	S3Region             string              `json:"s3Region,omitempty"`
	ExpectedBucketURL    string              `json:"expectedBucketURL,omitempty"`
	CloudflareToken      string              `json:"cloudflareToken,omitempty"`
	ObjectCredentials    *objectCredentials  `json:"objectCredentials,omitempty"`
	ObjectBudget         *objectBudgetConfig `json:"objectBudget,omitempty"`
}
type patch struct {
	Offset    int64  `json:"offset"`
	Data      []byte `json:"data"`
	LocalFile string `json:"localFile,omitempty"`
	Length    int64  `json:"length"`
}
type request struct {
	Op              string  `json:"op"`
	Handle          uint64  `json:"handle"`
	Config          config  `json:"config"`
	Path            string  `json:"path"`
	Destination     string  `json:"destination,omitempty"`
	Offset          int64   `json:"offset,omitempty"`
	Length          int     `json:"length,omitempty"`
	ExpectedVersion string  `json:"expectedVersion,omitempty"`
	OperationID     string  `json:"operationID,omitempty"`
	Size            int64   `json:"size,omitempty"`
	BaseVisibleSize int64   `json:"baseVisibleSize"`
	Patches         []patch `json:"patches,omitempty"`
	Mode            uint16  `json:"mode,omitempty"`
	Directory       bool    `json:"directory,omitempty"`
}
type entry struct {
	Path                string `json:"path"`
	Name                string `json:"name"`
	Inode               uint64 `json:"inode"`
	Size                int64  `json:"size"`
	Kind                string `json:"kind"`
	Mode                uint16 `json:"mode"`
	ModifiedNanoseconds int64  `json:"modifiedNanoseconds"`
	AccessedNanoseconds int64  `json:"accessedNanoseconds"`
	Version             string `json:"version"`
}
type response struct {
	VolumeIdentity string   `json:"volumeIdentity,omitempty"`
	ObjectPrefix   string   `json:"objectPrefix,omitempty"`
	OK             bool     `json:"ok"`
	Errno          int      `json:"errno,omitempty"`
	Error          string   `json:"error,omitempty"`
	Handle         uint64   `json:"handle,omitempty"`
	Entry          *entry   `json:"entry,omitempty"`
	Entries        []entry  `json:"entries,omitempty"`
	Data           []byte   `json:"data,omitempty"`
	Metrics        *metrics `json:"metrics,omitempty"`
}
type metrics struct {
	ObjectReadBytes      int64                `json:"objectReadBytes"`
	ObjectGetRequests    int64                `json:"objectGetRequests"`
	ApplicationReadBytes int64                `json:"applicationReadBytes"`
	ObjectBudget         *objectBudgetMetrics `json:"objectBudget,omitempty"`
}
type countingStorage struct {
	object.ObjectStorage
	bytes                atomic.Int64
	gets                 atomic.Int64
	countsDownloadedBody bool
}
type countingReader struct {
	io.ReadCloser
	bytes *atomic.Int64
}

func (r *countingReader) Read(b []byte) (int, error) {
	n, e := r.ReadCloser.Read(b)
	r.bytes.Add(int64(n))
	return n, e
}
func (s *countingStorage) Get(ctx context.Context, key string, off, limit int64, getters ...object.AttrGetter) (io.ReadCloser, error) {
	s.gets.Add(1)
	r, e := s.ObjectStorage.Get(ctx, key, off, limit, getters...)
	if e != nil {
		return nil, e
	}
	if s.countsDownloadedBody {
		return r, nil
	}
	return &countingReader{r, &s.bytes}, nil
}

type engine struct {
	sync.Mutex
	fs           *fs.FileSystem
	meta         meta.Meta
	ctx          meta.Context
	lockInode    meta.Ino
	owner        uint64
	storage      *countingStorage
	readBytes    atomic.Int64
	objectBudget *objectBudget
}

var engines = struct {
	sync.Mutex
	values map[uint64]*engine
	next   uint64
}{values: make(map[uint64]*engine)}

func token() string {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}
func normalized(p string) (string, error) {
	if !strings.HasPrefix(p, "/") || strings.ContainsRune(p, 0) {
		return "", syscall.EINVAL
	}
	for _, component := range strings.Split(p, "/") {
		if component == ".." || component == "." {
			return "", syscall.EINVAL
		}
	}
	p = path.Clean(p)
	if p == internalRoot || strings.HasPrefix(p, internalRoot+"/") {
		return "", syscall.EACCES
	}
	return p, nil
}
func errResponse(err error) response {
	code := int(syscall.EIO)
	var en syscall.Errno
	if errors.As(err, &en) {
		code = int(en)
	}
	return response{Errno: code, Error: "native operation failed"}
}
func eno(e syscall.Errno) error {
	if e == 0 {
		return nil
	}
	return e
}
func info(p string, st *fs.FileStat) entry {
	a := st.Attr()
	kind := "file"
	if st.IsDir() {
		kind = "directory"
	}
	if st.IsSymlink() {
		kind = "symlink"
	}
	return entry{Path: p, Name: path.Base(p), Inode: uint64(st.Inode()), Size: st.Size(), Kind: kind, Mode: a.Mode, ModifiedNanoseconds: a.Mtime*1000000000 + int64(a.Mtimensec), AccessedNanoseconds: a.Atime*1000000000 + int64(a.Atimensec), Version: fmt.Sprintf("%d:%d:%d:%d:%d:%d", st.Inode(), a.Length, a.Mtime, a.Mtimensec, a.Ctime, a.Ctimensec)}
}

// Reject symlinks before any public operation: this adapter intentionally does
// not expose symlinks, including aliases into the reserved control directory.
func (e *engine) checkPublicPath(p string) error {
	current := ""
	for _, component := range strings.Split(strings.TrimPrefix(p, "/"), "/") {
		if component == "" {
			continue
		}
		current += "/" + component
		st, code := e.fs.Lstat(e.ctx, current)
		if code == syscall.ENOENT {
			return nil
		}
		if code != 0 {
			return code
		}
		if st.IsSymlink() {
			return syscall.ENOTSUP
		}
	}
	return nil
}

func (e *engine) stat(p string) (*entry, error) {
	st, err := e.fs.Lstat(e.ctx, p)
	if err != 0 {
		return nil, err
	}
	v := info(p, st)
	return &v, nil
}

// This opt-in smoke fixture formats only a brand-new local SQLite database.
// The random format name scopes every remote object under a new volume prefix.
func reserveS3TestMetadata(c config) error {
	if c.CreateLocal || (c.CreateS3Test && c.CreateCloudflareTest) {
		return syscall.EINVAL
	}
	if c.CreateCloudflareTest {
		if !validCloudflareBucketURL(c.S3BucketURL) || c.CloudflareToken == "" {
			return syscall.EINVAL
		}
	} else {
		if c.ObjectCredentials == nil || c.ObjectCredentials.AccessKey == "" || c.ObjectCredentials.SecretKey == "" {
			return syscall.EINVAL
		}
		target, err := url.ParseRequestURI(c.S3BucketURL)
		if err != nil || target.Scheme != "https" || target.Hostname() == "" || target.User != nil || target.RawQuery != "" || target.ForceQuery || target.Fragment != "" || target.RawPath != "" {
			return syscall.EINVAL
		}
		bucket := strings.TrimPrefix(target.Path, "/")
		if !regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$`).MatchString(bucket) {
			return syscall.EINVAL
		}
	}
	if !strings.HasPrefix(c.MetadataURL, "sqlite3://") {
		return syscall.EINVAL
	}
	file := strings.TrimPrefix(c.MetadataURL, "sqlite3://")
	if !path.IsAbs(file) || path.Clean(file) != file || strings.ContainsAny(file, "?#%\x00") {
		return syscall.EINVAL
	}
	for _, suffix := range []string{"-wal", "-shm", "-journal"} {
		if _, err := os.Lstat(file + suffix); err == nil {
			return syscall.EEXIST
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	reserved, err := os.OpenFile(file, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	return reserved.Close()
}

func connect(c config) (*engine, error) {
	if c.MetadataURL == "" || c.CacheBytes < 0 {
		return nil, syscall.EINVAL
	}
	budget, budgetError := validatedObjectBudget(c.ObjectBudget)
	if budgetError != nil {
		return nil, budgetError
	}
	if budget != nil && (c.CreateLocal || c.CreateS3Test) {
		return nil, syscall.EINVAL
	}
	if c.ObjectCredentials != nil && (c.ObjectCredentials.AccessKey == "" || c.ObjectCredentials.SecretKey == "") {
		return nil, syscall.EINVAL
	}
	if c.CreateS3Test || c.CreateCloudflareTest {
		if err := reserveS3TestMetadata(c); err != nil {
			return nil, err
		}
	}
	// The embedded SDK must never log URL credentials or object-store secrets.
	utils.SetLogLevel(logrus.PanicLevel)
	mc := meta.DefaultConf()
	mc.Retries = 3
	mc.NoBGJob = true
	mc.OpenCache = 0
	m, clientError := meta.NewStreamDriveClient(c.MetadataURL, mc)
	if clientError != nil {
		return nil, clientError
	}
	if c.CreateLocal {
		if !strings.HasPrefix(c.MetadataURL, "sqlite3://") || !path.IsAbs(c.LocalObjectDirectory) {
			return nil, fmt.Errorf("local initialization requires SQLite and an absolute local object directory")
		}
		if err := os.MkdirAll(c.LocalObjectDirectory, 0700); err != nil {
			return nil, err
		}
		format := &meta.Format{Name: "streamdrive", UUID: token(), Storage: "file", Bucket: c.LocalObjectDirectory + "/", BlockSize: 4096, Compression: "none", DirStats: true, TrashDays: 1}
		if err := m.Init(format, false); err != nil {
			return nil, fmt.Errorf("initialize local metadata: %w", err)
		}
	}
	if c.CreateS3Test || c.CreateCloudflareTest {
		format := &meta.Format{Name: "streamdrive-smoke-" + token(), UUID: token(), Storage: "s3", Bucket: c.S3BucketURL, BlockSize: 4096, Compression: "none", DirStats: true, TrashDays: 1}
		if c.CreateCloudflareTest {
			format.Storage = "cloudflare-oauth"
		}
		if err := m.Init(format, false); err != nil {
			return nil, fmt.Errorf("initialize S3 test metadata failed")
		}
	}
	format, err := m.Load(true)
	if err != nil {
		return nil, fmt.Errorf("load JuiceFS metadata failed")
	}
	if err := format.Decrypt(); err != nil {
		return nil, fmt.Errorf("decrypt JuiceFS format failed")
	}
	if format.Shards > 1 || format.EncryptKey != "" || len(format.Tiers) > 1 || format.KerbConf != "" {
		return nil, fmt.Errorf("this bridge supports unsharded, single-tier volumes without JuiceFS RSA encryption or Kerberos")
	}
	if c.ExpectedBucketURL != "" && format.Bucket != c.ExpectedBucketURL {
		return nil, syscall.EXDEV
	}
	if budget != nil && format.Storage != "cloudflare-oauth" {
		return nil, syscall.EINVAL
	}
	accessKey, secretKey, sessionToken := format.AccessKey, format.SecretKey, format.SessionToken
	if c.ObjectCredentials != nil {
		if strings.ToLower(format.Storage) != "s3" {
			return nil, syscall.EINVAL
		}
		accessKey, secretKey, sessionToken = c.ObjectCredentials.AccessKey, c.ObjectCredentials.SecretKey, c.ObjectCredentials.SessionToken
	}
	if strings.ToLower(format.Storage) == "s3" && (accessKey == "" || secretKey == "") {
		return nil, syscall.EINVAL
	}
	var blob object.ObjectStorage
	var cloudflare *cloudflareStorage
	if format.Storage == "cloudflare-oauth" {
		if format.BlockSize > maxCloudflareObject/1024 {
			return nil, syscall.EINVAL
		}
		cloudflare, err = newCloudflareStorage(format.Bucket, c.CloudflareToken)
		if err == nil && budget != nil {
			cloudflare.setBudget(budget)
		}
		blob = cloudflare
	} else {
		bucketURL := format.Bucket
		if c.S3Region != "" {
			if format.Storage != "s3" || !regexp.MustCompile(`^[a-z0-9-]{1,64}$`).MatchString(c.S3Region) {
				return nil, syscall.EINVAL
			}
			u, e := url.Parse(bucketURL)
			if e != nil {
				return nil, syscall.EINVAL
			}
			q := u.Query()
			q.Set("streamdrive-region", c.S3Region)
			u.RawQuery = q.Encode()
			bucketURL = u.String()
		}
		blob, err = object.CreateStorage(strings.ToLower(format.Storage), bucketURL, accessKey, secretKey, sessionToken)
	}
	if err != nil {
		return nil, fmt.Errorf("initialize object storage failed")
	}
	prefixed := object.WithPrefix(blob, format.Name+"/")
	for id := range format.Tiers {
		if id != 0 {
			return nil, fmt.Errorf("nondefault storage tier unsupported")
		}
	}
	if tiered, ok := prefixed.(object.SupportTier); ok {
		if err := tiered.InitTiers(format.Tiers); err != nil {
			for _, tier := range format.Tiers {
				if tier.Sc != "" || tier.Tag != "" {
					return nil, fmt.Errorf("initialize storage tier failed")
				}
			}
		}
	}
	counted := &countingStorage{ObjectStorage: prefixed}
	if cloudflare != nil {
		counted.countsDownloadedBody = true
		cloudflare.downloaded = &counted.bytes
	}
	cc := chunk.Config{BlockSize: format.BlockSize * 1024, Compress: format.Compression, CacheDir: "memory", CacheMode: 0600, CacheSize: 0, FreeSpace: .1, AutoCreate: true, CacheFullBlock: true, CacheChecksum: chunk.CsFull, CacheEviction: chunk.EvictionLRU, CacheScanInterval: time.Minute, OSCache: true, MaxUpload: 4, MaxDownload: 8, MaxRetries: 3, GetTimeout: 30 * time.Second, PutTimeout: 30 * time.Second, BufferSize: 64 << 20, Readahead: 0, Prefetch: 0, Writeback: false, HashPrefix: format.HashPrefix}
	if c.MemoryMiB >= 32 && c.MemoryMiB <= 1024 {
		cc.BufferSize = uint64(c.MemoryMiB) << 20
	}
	cc.SelfCheck(format.UUID)
	store := chunk.NewCachedStore(counted, cc, nil)
	m.OnMsg(meta.DeleteSlice, func(args ...interface{}) error { return store.Remove(args[0].(uint64), int(args[1].(uint32))) })
	m.OnMsg(meta.CompactChunk, func(args ...interface{}) error {
		return vfs.Compact(cc, store, args[0].([]meta.Slice), args[1].(uint64), args[2].(uint8))
	})
	if err := m.NewSession(true); err != nil {
		return nil, fmt.Errorf("open JuiceFS session failed")
	}
	conf := &vfs.Config{Meta: mc, Format: *format, Chunk: &cc, AttrTimeout: 0, EntryTimeout: 0, DirEntryTimeout: 0}
	jf, err := fs.NewFileSystem(conf, m, store, nil)
	if err != nil {
		_ = m.CloseSession()
		return nil, err
	}
	connected := false
	defer func() {
		if !connected {
			_ = jf.Close()
		}
	}()
	ctx := meta.NewContext(uint32(os.Getpid()), uint32(os.Getuid()), []uint32{uint32(os.Getgid())})
	e := &engine{fs: jf, meta: m, ctx: ctx, owner: uint64(time.Now().UnixNano()), storage: counted, objectBudget: budget}
	if err := jf.MkdirAll(ctx, internalRoot, 0700, 0077); err != 0 {
		return nil, err
	}
	lock, errNo := jf.Create(ctx, internalRoot+"/lock", 0600, 0077)
	if errNo == 0 {
		e.lockInode = lock.Inode()
		_ = lock.Close(ctx)
	} else if errNo == syscall.EEXIST {
		st, code := jf.Stat(ctx, internalRoot+"/lock")
		if code != 0 {
			return nil, code
		}
		e.lockInode = st.Inode()
	} else {
		return nil, errNo
	}
	connected = true
	return e, nil
}
func (e *engine) lockCommit() error {
	deadline := time.Now().Add(10 * time.Second)
	for {
		err := e.meta.Flock(e.ctx, e.lockInode, e.owner, syscall.F_WRLCK, false)
		if err == 0 {
			return nil
		}
		if err != syscall.EAGAIN && err != syscall.EACCES {
			return err
		}
		if time.Now().After(deadline) {
			return syscall.EBUSY
		}
		time.Sleep(50 * time.Millisecond)
	}
}
func (e *engine) unlockCommit() {
	_ = e.meta.Flock(e.ctx, e.lockInode, e.owner, syscall.F_UNLCK, false)
}
func (e *engine) commit(r request) (*entry, error) {
	if r.BaseVisibleSize < 0 || r.BaseVisibleSize > r.Size {
		return nil, syscall.EINVAL
	}
	if r.OperationID == "" || len(r.OperationID) > 128 || strings.ContainsAny(r.OperationID, "/\x00") || r.Size < 0 {
		return nil, syscall.EINVAL
	}
	if err := e.lockCommit(); err != nil {
		return nil, err
	}
	defer e.unlockCommit()
	current, err := e.stat(r.Path)
	if err != nil && !errors.Is(err, syscall.ENOENT) {
		return nil, err
	}
	if current != nil {
		done, code := e.fs.GetXattr(e.ctx, r.Path, "user.streamdrive.operation")
		if code == 0 && string(done) == r.OperationID {
			return current, nil
		}
		if current.Kind != "file" {
			return nil, syscall.EISDIR
		}
		if current.Version != r.ExpectedVersion {
			return nil, syscall.ESTALE
		}
	} else if r.ExpectedVersion != "" {
		return nil, syscall.ESTALE
	}
	stage := internalRoot + "/stage-" + r.OperationID
	// A prior crash may leave this unreferenced stage. The durable local journal is authoritative.
	if code := e.fs.Delete(e.ctx, stage); code != 0 && code != syscall.ENOENT {
		return nil, code
	}
	if current != nil {
		if code := e.fs.Clone(e.ctx, r.Path, stage, true); code != 0 {
			return nil, code
		}
	} else {
		f, code := e.fs.Create(e.ctx, stage, r.Mode, 0022)
		if code != 0 {
			return nil, code
		}
		if code := f.Close(e.ctx); code != 0 {
			return nil, code
		}
	}
	defer e.fs.Delete(e.ctx, stage)
	f, code := e.fs.Open(e.ctx, stage, vfs.MODE_MASK_W)
	if code != 0 {
		return nil, code
	}
	closed := false
	defer func() {
		if !closed {
			_ = f.Close(e.ctx)
		}
	}()
	if code := f.Truncate(e.ctx, uint64(r.BaseVisibleSize)); code != 0 {
		return nil, code
	}
	if code := f.Truncate(e.ctx, uint64(r.Size)); code != 0 {
		return nil, code
	}
	for _, p := range r.Patches {
		if p.Offset < 0 || p.Length < 0 || p.Offset > r.Size-p.Length {
			return nil, syscall.EINVAL
		}
		if p.LocalFile != "" {
			local, err := os.Open(p.LocalFile)
			if err != nil {
				return nil, err
			}
			buf := make([]byte, 1<<20)
			offset := p.Offset
			remaining := p.Length
			for remaining > 0 {
				requested := int64(len(buf))
				if remaining < requested {
					requested = remaining
				}
				n, er := io.ReadFull(local, buf[:requested])
				if n > 0 {
					written, code := f.Pwrite(e.ctx, buf[:n], offset)
					if code != 0 {
						local.Close()
						return nil, code
					}
					if written != n {
						local.Close()
						return nil, io.ErrShortWrite
					}
					offset += int64(n)
					remaining -= int64(n)
				}
				if er != nil {
					local.Close()
					return nil, er
				}
			}
			if err := local.Close(); err != nil {
				return nil, err
			}
		} else {
			if int64(len(p.Data)) != p.Length {
				return nil, syscall.EINVAL
			}
			if len(p.Data) > maxRead {
				return nil, syscall.EFBIG
			}
			written, code := f.Pwrite(e.ctx, p.Data, p.Offset)
			if code != 0 {
				return nil, code
			}
			if written != len(p.Data) {
				return nil, io.ErrShortWrite
			}
		}
	}
	if code := f.Truncate(e.ctx, uint64(r.Size)); code != 0 {
		return nil, code
	}
	if code := f.Fsync(e.ctx); code != 0 {
		return nil, code
	}
	if code := f.Close(e.ctx); code != 0 {
		return nil, code
	}
	closed = true
	if code := e.fs.SetXattr(e.ctx, stage, "user.streamdrive.operation", []byte(r.OperationID), 0); code != 0 {
		return nil, code
	}
	// Other StreamDrive clients share the lock; external JuiceFS writers must be quiesced.
	if code := e.fs.Rename(e.ctx, stage, r.Path, 0); code != 0 {
		return nil, code
	}
	return e.stat(r.Path)
}
func dispatch(r request) response {
	if r.Op == "connect" {
		e, err := connect(r.Config)
		if err != nil {
			return errResponse(err)
		}
		engines.Lock()
		engines.next++
		id := engines.next
		engines.values[id] = e
		engines.Unlock()
		return response{OK: true, Handle: id, ObjectPrefix: e.meta.GetFormat().Name + "/", VolumeIdentity: e.meta.GetFormat().UUID}
	}
	engines.Lock()
	e := engines.values[r.Handle]
	engines.Unlock()
	if e == nil {
		return errResponse(syscall.EBADF)
	}
	e.Lock()
	defer e.Unlock()
	var err error
	if r.Op != "close" && r.Op != "metrics" && r.Op != "identity" {
		r.Path, err = normalized(r.Path)
		if err != nil {
			return errResponse(err)
		}
	}
	if r.Op != "close" && r.Op != "metrics" && r.Op != "identity" {
		if err := e.checkPublicPath(r.Path); err != nil {
			return errResponse(err)
		}
	}
	out := response{OK: true}
	switch r.Op {
	case "close":
		err = e.fs.Close()
		engines.Lock()
		delete(engines.values, r.Handle)
		engines.Unlock()
	case "stat":
		out.Entry, err = e.stat(r.Path)
	case "list":
		var f *fs.File
		var code syscall.Errno
		f, code = e.fs.Open(e.ctx, r.Path, 0)
		if code != 0 {
			err = code
			break
		}
		defer f.Close(e.ctx)
		var entries []*meta.Entry
		entries, code = f.ReaddirPlus(e.ctx, 0)
		if code != 0 {
			err = code
			break
		}
		out.Entries = []entry{}
		for _, item := range entries {
			name := string(item.Name)
			if name == "." || name == ".." || (r.Path == "/" && name == ".streamdrive") {
				continue
			}
			out.Entries = append(out.Entries, info(path.Join(r.Path, name), fs.AttrToFileInfo(item.Inode, item.Attr)))
		}
	case "read":
		if r.Offset < 0 || r.Length < 0 || r.Length > maxRead {
			return errResponse(syscall.EINVAL)
		}
		f, code := e.fs.Open(e.ctx, r.Path, vfs.MODE_MASK_R)
		if code != 0 {
			err = code
			break
		}
		defer f.Close(e.ctx)
		out.Data = make([]byte, r.Length)
		n, er := f.Pread(e.ctx, out.Data, r.Offset)
		out.Data = out.Data[:n]
		e.readBytes.Add(int64(n))
		if er != nil && er != io.EOF {
			err = er
		}
	case "commit":
		out.Entry, err = e.commit(r)
	case "mkdir":
		if er := e.lockCommit(); er != nil {
			err = er
			break
		}
		defer e.unlockCommit()
		mode := r.Mode
		if mode == 0 {
			mode = 0755
		}
		err = eno(e.fs.Mkdir(e.ctx, r.Path, mode, 0022))
		if err == nil {
			out.Entry, err = e.stat(r.Path)
		}
	case "remove":
		if er := e.lockCommit(); er != nil {
			err = er
			break
		}
		defer e.unlockCommit()
		if r.Directory {
			err = eno(e.fs.Rmdir(e.ctx, r.Path))
		} else {
			err = eno(e.fs.Unlink(e.ctx, r.Path))
		}
	case "rename":
		r.Destination, err = normalized(r.Destination)
		if err != nil {
			break
		}
		if err = e.checkPublicPath(r.Destination); err != nil {
			break
		}
		if er := e.lockCommit(); er != nil {
			err = er
			break
		}
		defer e.unlockCommit()
		err = eno(e.fs.Rename(e.ctx, r.Path, r.Destination, 0))
		if err == nil {
			out.Entry, err = e.stat(r.Destination)
		}
	case "identity":
		out.VolumeIdentity = e.meta.GetFormat().UUID
		if out.VolumeIdentity == "" {
			err = syscall.ENOTSUP
		}
	case "metrics":
		out.Metrics = &metrics{ObjectReadBytes: e.storage.bytes.Load(), ObjectGetRequests: e.storage.gets.Load(), ApplicationReadBytes: e.readBytes.Load(), ObjectBudget: e.objectBudget.snapshot()}
	default:
		err = syscall.ENOSYS
	}
	if err != nil {
		return errResponse(err)
	}
	return out
}

//export sd_call
func sd_call(input *C.char) (output *C.char) {
	defer func() {
		if recover() != nil {
			output = C.CString(`{"ok":false,"errno":5,"error":"native bridge failure"}`)
		}
	}()
	var r request
	if input == nil {
		return C.CString(`{"ok":false,"errno":22,"error":"missing request"}`)
	}
	if err := json.Unmarshal([]byte(C.GoString(input)), &r); err != nil {
		return C.CString(`{"ok":false,"errno":22,"error":"invalid request"}`)
	}
	out, _ := json.Marshal(dispatch(r))
	return C.CString(string(out))
}

//export sd_free
func sd_free(p *C.char) { C.free(unsafe.Pointer(p)) }
func main()             {}
