package main

import (
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// owned reconnects the fixture drive as this Mac ("mac-a") and registers it for dispatch.
func owned(t *testing.T) (*engine, config, uint64) {
	t.Helper()
	_, c := fixture(t)
	c.OwnerID, c.OwnerName, c.DriveName = "mac-a", "Studio Mac", "Studio"
	e, err := connect(c)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = e.fs.Close() })
	engines.Lock()
	engines.next++
	id := engines.next
	engines.values[id] = e
	engines.Unlock()
	t.Cleanup(func() { engines.Lock(); delete(engines.values, id); engines.Unlock() })
	return e, c, id
}

func TestConnectClaimsAnUnownedDrive(t *testing.T) {
	e, c, id := owned(t)
	record, err := readOwner(e.storage)
	if err != nil || record == nil || record.ID != "mac-a" || record.Name != "Studio Mac" || record.Drive != "Studio" || time.Since(record.At) > time.Minute {
		t.Fatalf("owner after connect: %+v, %v", record, err)
	}
	reported := dispatch(request{Op: "driveOwner", Config: config{LocalObjectDirectory: c.LocalObjectDirectory, VolumeName: e.meta.GetFormat().Name}})
	if !reported.OK || reported.Owner == nil || reported.Owner.ID != "mac-a" {
		t.Fatalf("driveOwner: %+v", reported)
	}
	if state := dispatch(request{Op: "ownership", Handle: id}); !state.OK || state.OwnedElsewhere {
		t.Fatalf("ownership of an own drive: %+v", state)
	}
}

// After another Mac recovers the drive, this Mac's writes and backups are refused,
// while reading stays possible.
func TestWritesStopOnceAnotherMacOwnsTheDrive(t *testing.T) {
	e, _, id := owned(t)
	if made := dispatch(request{Op: "mkdir", Handle: id, Path: "/before"}); !made.OK {
		t.Fatalf("mkdir as owner failed: %s", made.Error)
	}
	if err := writeOwner(e.storage, "mac-b", "Laptop", "Studio"); err != nil {
		t.Fatal(err)
	}
	saved := ownerRecheck
	ownerRecheck = 0
	defer func() { ownerRecheck = saved }()
	expectErrno(t, dispatch(request{Op: "mkdir", Handle: id, Path: "/after"}), syscall.EROFS)
	if state := dispatch(request{Op: "ownership", Handle: id}); !state.OK || !state.OwnedElsewhere || state.OwnerName != "Laptop" {
		t.Fatalf("ownership after a takeover: %+v", state)
	}
	expectErrno(t, dispatch(request{Op: "backupMeta", Handle: id}), syscall.EROFS)
	expectErrno(t, dispatch(request{Op: "rename", Handle: id, Path: "/before", Destination: "/renamed"}), syscall.EROFS)
	if listed := dispatch(request{Op: "list", Handle: id, Path: "/"}); !listed.OK {
		t.Fatalf("reading failed after losing ownership: %s", listed.Error)
	}
	// The new owner's record is never overwritten by the old owner.
	if record, _ := readOwner(e.storage); record == nil || record.ID != "mac-b" {
		t.Fatalf("owner record changed: %+v", record)
	}
}

func TestRecoveryRecordsTheNewOwner(t *testing.T) {
	e, c, _, _ := backedUp(t)
	request := restoreRequest(c.LocalObjectDirectory, filepath.Join(t.TempDir(), "restored.db"), e.meta.GetFormat().Name)
	request.Config.OwnerID, request.Config.OwnerName = "mac-b", "Laptop"
	if restored := dispatch(request); !restored.OK {
		t.Fatalf("restoreMeta failed: %s", restored.Error)
	}
	if record, err := readOwner(e.storage); err != nil || record == nil || record.ID != "mac-b" || record.Name != "Laptop" {
		t.Fatalf("owner after recovery: %+v, %v", record, err)
	}
}

// An idle drive learns of a takeover when asked to refresh, without trying a write.
func TestRefreshedOwnershipSeesATakeoverWithoutWriting(t *testing.T) {
	e, _, id := owned(t)
	if err := writeOwner(e.storage, "mac-b", "Laptop", "Studio"); err != nil {
		t.Fatal(err)
	}
	if cached := dispatch(request{Op: "ownership", Handle: id}); !cached.OK || cached.OwnedElsewhere {
		t.Fatalf("a cached answer read the bucket: %+v", cached)
	}
	if fresh := dispatch(request{Op: "ownership", Handle: id, Refresh: true}); !fresh.OK || !fresh.OwnedElsewhere || fresh.OwnerName != "Laptop" {
		t.Fatalf("refreshed ownership: %+v", fresh)
	}
}
