package main

// Restoring a drive on another Mac. A drive's objects live in its bucket under its
// volume name, and so do backups of its index: JuiceFS dumps under <volume>/meta/, with
// meta/latest naming the newest (vfs.StreamDriveBackup). restoreMeta loads one into a
// new SQLite file on this Mac; listDrives finds the drives in a bucket that can list.

import (
	"compress/gzip"
	"context"
	"io"
	"os"
	"path"
	"regexp"
	"sort"
	"strings"
	"syscall"

	"github.com/juicedata/juicefs/pkg/meta"
	"github.com/juicedata/juicefs/pkg/object"
	"github.com/juicedata/juicefs/pkg/utils"
	"github.com/juicedata/juicefs/pkg/vfs"
	"github.com/sirupsen/logrus"
)

// volumeName matches the names JuiceFS's format command accepts.
var volumeName = regexp.MustCompile(`^[a-z0-9][a-z0-9\-]{1,61}[a-z0-9]$`)

type storedDrive struct {
	Volume       string `json:"volume"`
	LatestBackup string `json:"latestBackup"`
}

// bucketStorage opens the bucket a connection names, without any drive's index, and
// the bucket URL a drive formatted there records. Cloudflare sign-in storage cannot list.
func bucketStorage(c config) (blob object.ObjectStorage, bucketURL string, listable bool, err error) {
	quietLogs.Do(func() { utils.SetLogLevel(logrus.PanicLevel) }) // as in connect: never log URLs
	switch {
	case c.LocalObjectDirectory != "": // a local folder standing in for a bucket, in tests
		if !path.IsAbs(c.LocalObjectDirectory) {
			return nil, "", false, syscall.EINVAL
		}
		bucketURL = c.LocalObjectDirectory + "/"
		blob, err = object.CreateStorage("file", bucketURL, "", "", "")
		return blob, bucketURL, true, err
	case c.CloudflareToken != "":
		if !validCloudflareBucketURL(c.S3BucketURL) {
			return nil, "", false, syscall.EINVAL
		}
		storage, err := newCloudflareStorage(c.S3BucketURL, c.CloudflareToken)
		if err != nil {
			return nil, "", false, err
		}
		return storage, c.S3BucketURL, false, nil
	default:
		if c.ObjectCredentials == nil || c.ObjectCredentials.AccessKey == "" || c.ObjectCredentials.SecretKey == "" || !validS3BucketURL(c.S3BucketURL) {
			return nil, "", false, syscall.EINVAL
		}
		target := c.S3BucketURL
		if c.S3Region != "" {
			if target, err = regionalBucketURL(target, c.S3Region); err != nil {
				return nil, "", false, err
			}
		}
		credentials := c.ObjectCredentials
		blob, err = object.CreateStorage("s3", target, credentials.AccessKey, credentials.SecretKey, credentials.SessionToken)
		return blob, c.S3BucketURL, true, err
	}
}

// latestBackup reads meta/latest, or, when an older backup predates the pointer, picks
// the newest dump by name (they sort by time) on storage that can list.
func latestBackup(volume object.ObjectStorage, listable bool) (string, error) {
	pointer, err := volume.Get(context.Background(), vfs.StreamDriveBackupPointer, 0, 1024)
	if err != nil && !isNotFound(err) {
		return "", err
	}
	if err == nil {
		defer pointer.Close()
		value, err := io.ReadAll(io.LimitReader(pointer, 1024))
		if err != nil {
			return "", err
		}
		if key := strings.TrimSpace(string(value)); backupKey.MatchString(key) {
			return key, nil
		}
		return "", syscall.EINVAL
	}
	if !listable {
		return "", syscall.ENOENT
	}
	var dumps []string
	if err := listAll(volume, "meta/", func(item object.Object) {
		if backupKey.MatchString(item.Key()) {
			dumps = append(dumps, item.Key())
		}
	}); err != nil {
		return "", err
	}
	if len(dumps) == 0 {
		return "", syscall.ENOENT
	}
	sort.Strings(dumps)
	return dumps[len(dumps)-1], nil
}

// restoreMeta loads a drive's backed-up index into a new SQLite file. The dump must
// describe the same volume in the same bucket. Returns the dump's key and the volume's
// UUID. On failure the new file is removed, so a retry starts clean.
func restoreMeta(c config) (key string, identity string, err error) {
	if !volumeName.MatchString(c.VolumeName) || (c.BackupKey != "" && !backupKey.MatchString(c.BackupKey)) {
		return "", "", syscall.EINVAL
	}
	file, err := reserveMetadataFile(c.MetadataURL)
	if err != nil {
		return "", "", err
	}
	restored := false
	defer func() {
		if !restored {
			for _, suffix := range []string{"", "-wal", "-shm", "-journal"} {
				_ = os.Remove(file + suffix)
			}
		}
	}()
	blob, bucketURL, listable, err := bucketStorage(c)
	if err != nil {
		return "", "", err
	}
	volume := object.WithPrefix(blob, c.VolumeName+"/")
	key = c.BackupKey
	if key == "" {
		if key, err = latestBackup(volume, listable); err != nil {
			return "", "", err
		}
	}
	dump, err := volume.Get(context.Background(), key, 0, -1)
	if err != nil {
		return "", "", err
	}
	defer dump.Close()
	unzipped, err := gzip.NewReader(dump)
	if err != nil {
		return "", "", syscall.EINVAL
	}
	m, err := meta.NewStreamDriveClient(c.MetadataURL, meta.DefaultConf())
	if err != nil {
		return "", "", err
	}
	defer m.Shutdown()
	if err := m.LoadMeta(unzipped); err != nil {
		return "", "", err
	}
	format, err := m.Load(true)
	if err != nil {
		return "", "", err
	}
	if format.Name != c.VolumeName || format.Bucket != bucketURL {
		return "", "", syscall.EXDEV
	}
	// The recovered drive is this Mac's now; another Mac that had it stops writing.
	if c.OwnerID != "" {
		if err := writeOwner(volume, c.OwnerID, c.OwnerName); err != nil {
			return "", "", err
		}
	}
	restored = true
	return key, format.UUID, nil
}

// listDrives finds the drives backed up in a bucket: top-level folders with a backup.
func listDrives(c config) ([]storedDrive, error) {
	blob, _, listable, err := bucketStorage(c)
	if err != nil {
		return nil, err
	}
	if !listable {
		return nil, syscall.ENOTSUP
	}
	var candidates []string
	if err := listAll(blob, "", func(folder object.Object) {
		// ParaAir creates drives as streamdrive-*; other folders are the user's own data.
		name := strings.TrimSuffix(folder.Key(), "/")
		if folder.IsDir() && strings.HasPrefix(name, "streamdrive") && volumeName.MatchString(name) {
			candidates = append(candidates, name)
		}
	}); err != nil {
		return nil, err
	}
	drives := []storedDrive{}
	for _, name := range candidates {
		if key, err := latestBackup(object.WithPrefix(blob, name+"/"), true); err == nil {
			drives = append(drives, storedDrive{Volume: name, LatestBackup: key})
		}
	}
	return drives, nil
}

// listAll walks every page of a delimited listing.
func listAll(storage object.ObjectStorage, prefix string, visit func(object.Object)) error {
	start, token := "", ""
	for {
		items, more, next, err := storage.List(context.Background(), prefix, start, token, "/", 1000, false)
		if err != nil {
			return err
		}
		for _, item := range items {
			visit(item)
		}
		if !more || len(items) == 0 {
			return nil
		}
		start, token = items[len(items)-1].Key(), next
	}
}
