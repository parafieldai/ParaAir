package main

// One Mac writes a drive at a time. Each Mac keeps its own copy of the drive's index,
// and JuiceFS names data objects by IDs that copy hands out, so two Macs writing one
// drive would overwrite each other's data. The drive's owner is recorded in its bucket
// at <volume>/meta/owner. A connection that knows its owner identity claims the drive
// when it is unowned or already its own, and refuses every write, including index
// backups, once the record names another Mac: a recovered drive belongs to the Mac
// that recovered it.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"syscall"
	"time"

	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/juicedata/juicefs/pkg/object"
)

const ownerKey = "meta/owner"

// ownerRecheck bounds how stale this Mac's view of the owner may be before a write.
// Shorter narrows the window in which a Mac that just lost the drive may still
// publish; each recheck is one small GET, only while writing.
var ownerRecheck = 10 * time.Second

type ownerRecord struct {
	ID   string    `json:"id"`
	Name string    `json:"name"`
	At   time.Time `json:"at"`
	// The drive's name in Finder, so another Mac can tell drives apart.
	Drive string `json:"drive,omitempty"`
}

// readOwner returns nil when the drive has no owner record yet.
func readOwner(volume object.ObjectStorage) (*ownerRecord, error) {
	reader, err := volume.Get(context.Background(), ownerKey, 0, 4096)
	if err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, err
	}
	defer reader.Close()
	value, err := io.ReadAll(io.LimitReader(reader, 4096))
	if err != nil {
		return nil, err
	}
	var record ownerRecord
	if err := json.Unmarshal(value, &record); err != nil || record.ID == "" {
		return nil, syscall.EINVAL
	}
	return &record, nil
}

func writeOwner(volume object.ObjectStorage, id, name, drive string) error {
	// Whole seconds: every ISO 8601 decoder reads them, fractions not always.
	value, err := json.Marshal(ownerRecord{ID: id, Name: name, At: time.Now().UTC().Truncate(time.Second), Drive: drive})
	if err != nil {
		return err
	}
	return volume.Put(context.Background(), ownerKey, bytes.NewReader(value))
}

// isNotFound recognizes a missing key: local storage reports os.ErrNotExist, the
// Cloudflare adapter ENOENT, and JuiceFS's S3 Get passes the AWS error through
// (NoSuchKey, or a bare 404 from some S3-compatible services).
func isNotFound(err error) bool {
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ENOENT) {
		return true
	}
	var missing *types.NoSuchKey
	var status *awshttp.ResponseError
	return errors.As(err, &missing) || (errors.As(err, &status) && status.HTTPStatusCode() == 404) ||
		strings.Contains(err.Error(), "NoSuchKey")
}

// claimOwner runs at connect. Offline, nothing is claimed and the first write checks.
func (e *engine) claimOwner(name, drive string) {
	if e.ownerID == "" {
		return
	}
	record, err := readOwner(e.storage)
	if err != nil {
		return
	}
	if record != nil && record.ID != e.ownerID {
		e.foreign.Store(true)
		e.foreignName.Store(&record.Name)
	} else {
		e.foreign.Store(false)
		_ = writeOwner(e.storage, e.ownerID, name, drive)
	}
	e.ownerChecked.Store(time.Now().UnixNano())
}

// ensureOwner fails a write with EROFS once another Mac owns the drive, rechecking the
// record at most once a minute.
func (e *engine) ensureOwner() error {
	if e.ownerID == "" {
		return nil
	}
	now := time.Now().UnixNano()
	if now-e.ownerChecked.Load() >= int64(ownerRecheck) {
		record, err := readOwner(e.storage)
		if err != nil {
			return err
		}
		e.foreign.Store(record != nil && record.ID != e.ownerID)
		if record != nil {
			e.foreignName.Store(&record.Name)
		}
		e.ownerChecked.Store(now)
	}
	if e.foreign.Load() {
		return syscall.EROFS
	}
	return nil
}

// driveOwner answers who owns a backed-up drive, before a recovery.
func driveOwner(c config) (*ownerRecord, error) {
	if !volumeName.MatchString(c.VolumeName) {
		return nil, syscall.EINVAL
	}
	blob, _, _, err := bucketStorage(c)
	if err != nil {
		return nil, err
	}
	return readOwner(object.WithPrefix(blob, c.VolumeName+"/"))
}
