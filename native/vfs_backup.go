// StreamDrive embedding adapter. Compiled beside the pinned JuiceFS package.
// Upstream's Backup loops forever on a timer inside a mounted client. The embedded
// bridge backs up on request instead (the Swift engine decides when), using the same
// dump, object name (meta/dump-<UTC>.json.gz), temporary file and rotation, so
// `juicefs load` and ParaAir restore the same backups.
package vfs

import (
	"time"

	"github.com/juicedata/juicefs/pkg/meta"
	"github.com/juicedata/juicefs/pkg/object"
)

// StreamDriveBackup dumps the whole tree without secrets or trash into
// blob/meta/, records the time like upstream, and prunes older dumps on success.
// It returns the dump's key relative to blob.
func StreamDriveBackup(m meta.Meta, blob object.ObjectStorage, now time.Time) (string, error) {
	var iused, dummy uint64
	_ = m.StatFS(meta.Background(), meta.RootInode, &dummy, &dummy, &iused, &dummy)
	if _, err := backup(m, blob, now, iused < 1e5, true); err != nil {
		return "", err
	}
	_ = m.SetXattr(meta.Background(), 0, "lastBackup", []byte(now.Format(time.RFC3339)), meta.XattrCreateOrReplace)
	cleanupBackups(blob, now)
	return "meta/dump-" + now.UTC().Format("2006-01-02-150405") + ".json.gz", nil
}
