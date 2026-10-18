// StreamDrive embedding adapter. Compiled beside the pinned JuiceFS package.
// Upstream's Backup loops forever on a timer inside a mounted client. The embedded
// bridge backs up on request instead (the Swift engine decides when), with upstream's
// dump, object name (meta/dump-<UTC>.json.gz) and rotation, so `juicefs load` and
// ParaAir restore the same backups.
package vfs

import (
	"compress/gzip"
	"context"
	"io"
	"os"
	"time"

	"github.com/juicedata/juicefs/pkg/meta"
	"github.com/juicedata/juicefs/pkg/object"
)

// StreamDriveBackup dumps the whole tree without secrets or trash into blob/meta/,
// records the time like upstream, and prunes older dumps in the background as
// upstream does. It returns the dump's key relative to blob. The dump is staged in a
// uniquely named temporary file: upstream's fixed $TMPDIR/meta/<name> would be shared
// by every extension process serving a drive, since they share one container.
func StreamDriveBackup(m meta.Meta, blob object.ObjectStorage, now time.Time) (string, error) {
	var iused, dummy uint64
	_ = m.StatFS(meta.Background(), meta.RootInode, &dummy, &dummy, &iused, &dummy)
	staged, err := os.CreateTemp("", "streamdrive-meta-*.json.gz")
	if err != nil {
		return "", err
	}
	defer os.Remove(staged.Name())
	defer staged.Close()
	zw, _ := gzip.NewWriterLevel(staged, gzip.BestSpeed)
	if err := m.DumpMeta(zw, 0, 2, false, iused < 1e5, true); err != nil { // 0: the whole tree
		_ = zw.Close()
		return "", err
	}
	if err := zw.Close(); err != nil {
		return "", err
	}
	if _, err := staged.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	key := "meta/dump-" + now.UTC().Format("2006-01-02-150405") + ".json.gz"
	if err := blob.Put(context.Background(), key, staged); err != nil {
		return "", err
	}
	_ = m.SetXattr(meta.Background(), 0, "lastBackup", []byte(now.Format(time.RFC3339)), meta.XattrCreateOrReplace)
	go cleanupBackups(blob, now)
	return key, nil
}
