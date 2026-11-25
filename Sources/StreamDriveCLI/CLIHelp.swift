import Foundation

enum CLIHelp {
    static func text(_ topic: String?) -> String {
        switch topic {
        case "connect":
            return """
            Usage: paraair connect PROFILE [options]
              --metadata-url URI     Existing formatted JuiceFS metadata endpoint; no credentials or query
              --library PATH         Pinned libstreamdrive.dylib for CLI storage access
              --connection ID        Saved storage connection from the Mac app (no secrets)
              --cloud-account ID     ParaAir Cloud account signed in with the Mac app (see cloud-accounts)
              --cloud-drive ID       ParaAir Cloud drive to attach; requires --cloud-account
              --cloud-drive-name NAME
                                     The same, by the drive's exact name (exit 14 when none or several match)
              --credential-id ID     Metadata URI stored by the app's secure Keychain dialog
              --mount-point PATH     Empty directory for the Finder volume
              --cache-mib N          Evictable touched-block cache limit (default 1024 MiB)
              --min-free-mib N       Free-space reserve (default 5120 MiB)
              --block-size N         Read/cache block size in bytes (4096–8388608; default 1048576,
                                     4194304 with --connection; ParaAir Cloud requires 4194304)
              --journal-mib N        Pending-write admission limit (default 4096 MiB)
              --new-state-folder     With --cloud-account: attach the drive in a state folder of its own under
                                     ~/Library/Application Support/ParaAir/Cloud Drives, sharing the account's
                                     sign-in from the folder it is in (a state folder holds one drive). Then mount
                                     with --state-dir set to the stateDirectory it prints; the app learns the folder
              --conflict-copies      Save a change that loses to another device's beside the file as
                                     "NAME (conflict YYYY-MM-DD).ext" instead of waiting for resolve (see settings)
              --replace             Explicitly replace an unmounted profile configuration (keeps its block size
                                    unless --block-size is given)
              --fixture-root PATH   Explicit local-directory test adapter; never a remote fallback

            connect saves a reference. It does not format storage, test connectivity or mount it.
            Create new managed cloud volumes in the Mac app. --connection selects its saved authorization.
            --cloud-account attaches an existing ParaAir Cloud drive after checking it with the service;
            it cannot be combined with --metadata-url, --library, --credential-id, --fixture-root or --connection.
            Secret URLs are entered through the app's secure dialog and stored in Keychain.
            """ + "\n"
        case "trash", "restore":
            return """
            Usage: paraair trash PROFILE [--json]
                   paraair restore PROFILE NODE_ID [--to PATH] [--json]
            ParaAir Cloud profiles only. trash lists deleted files that can still be restored.
            restore puts one back at its original path, or at --to PATH.
            """ + "\n"
        case "stored-drives", "recover":
            return """
            Usage: paraair stored-drives --connection ID [--library PATH] [--json]
                   paraair recover PROFILE --connection ID --volume NAME [--backup KEY] [--take-over] [--library PATH] [--json]
            Drives back up their index into their own bucket (at most hourly, after changes).
            stored-drives lists the drives backed up in a connection's bucket; connections made
            with Cloudflare sign-in cannot list, so find the drive's folder in the bucket instead.
            recover opens one in an empty state folder from its newest backup (or --backup KEY);
            changes made after that backup are missing. One Mac writes a drive at a time: recover
            refuses a drive another Mac used within a day unless --take-over is given, and the
            recovered drive is this Mac's; the other Mac stops writing to it and keeps its
            unsaved changes.
            """ + "\n"
        case "cache":
            return """
            Usage: paraair cache PROFILE [--evict] [--limit-mib N] [--json]
            --evict removes clean, unpinned cache blocks. Dirty writes and pins are retained.
            Changing the limit requires an unmounted profile; remount to apply it.
            Pins, durable pending writes and metadata consume disk beyond the evictable cache budget.
            """ + "\n"
        case "pin", "unpin":
            return """
            Usage: paraair \(topic!) PROFILE [/path] [--json]
            pin explicitly downloads a file or directory tree for offline reads and may exceed the cache budget.
            unpin makes those clean blocks eligible for eviction; it does not discard pending writes.
            """ + "\n"
        case "uploads":
            return """
            Usage: paraair uploads PROFILE [--retry] [--json]
            Inspect pending writes and conflicts. --retry publishes eligible journaled writes.
            Conflicts stay on this Mac until resolved (see conflicts); exit 3 means records remain after retry.
            """ + "\n"
        case "settings":
            return """
            Usage: paraair settings PROFILE [--conflict-copies on|off] [--json]
            Shows or changes a drive's settings on this Mac. With conflict copies on, a file whose upload finds a
            newer version from another device keeps that version, and this Mac's change is saved beside it as
            "NAME (conflict YYYY-MM-DD).ext" (then "... 2", "... 3"), which uploads like any new file. Nothing is
            merged. conflict-info tells where a copy came from. A mounted drive takes a change at its next mount.
            """ + "\n"
        case "versions", "cat-version", "restore-version":
            return """
            Usage: paraair versions (PROFILE PATH | MOUNTED_PATH) [--before CURSOR] [--limit N] [--json]
                   paraair cat-version (PROFILE PATH | MOUNTED_PATH) VERSION
                   paraair restore-version (PROFILE PATH | MOUNTED_PATH) VERSION [--expected-version VERSION] [--json]
            ParaAir Cloud keeps replaced versions 30 days (Personal) or 90 (Team). versions lists one page, newest
            first: {path, versions: [{version, size, createdAt, author, current, expiresAt}], nextBefore}; pass
            nextBefore as --before for the next page. author is {userId, email}, or {credential, name, createdBy}
            for a service credential. cat-version writes the version's bytes to standard output, unchanged (exit 0
            only when all of them were written). restore-version makes a version current again, as a new version;
            with --expected-version it refuses (exit 16) when the file's current version is another one.
            A MOUNTED_PATH such as /Volumes/Team/projects/plan.md names the drive and the file in one argument.
            """ + "\n"
        case "conflict-info":
            return """
            Usage: paraair conflict-info (PROFILE PATH | MOUNTED_PATH) [--json]
            Where a conflict copy came from: {path, original, baseVersion, theirsVersion, createdAt, source}.
            baseVersion is the version this Mac's change was based on (null for a file new on that Mac),
            theirsVersion the version it lost to. source is "this-mac" for a copy saved here, or "service" for one
            another Mac saved (then with its author). Exit 17 when the file isn't a known conflict copy.
            """ + "\n"
        case "changes":
            return """
            Usage: paraair changes (PROFILE [FOLDER] | MOUNTED_PATH) [--since CURSOR] [--follow [--push] [--interval SECONDS]] [--json]
            A ParaAir Cloud drive's change feed (kept 30 days). Without --since and --follow: the cursor to start
            from. With --since: the changes after it. --follow keeps polling (every 3 s, or --interval) and prints
            each change as it comes. --follow --push waits for ParaAir Cloud to say a change was made instead of
            polling (a change shows within about a second, and an idle drive costs the service almost nothing),
            and polls every 3 s (or --interval) only while that connection is down. Same output either way.
            With --json each line is one object: first {"following": true, "cursor": N}
            when following, then {cursor, change, kind, path, fromPath?, rescan?, version, at, author} per change,
            and {"reset": true, "cursor": N} when changes after your cursor were pruned (rescan, then go on).
            change is create, write, delete, move, restore, mkdir or purge; rescan asks to list that folder again.
            Only changes at or under FOLDER (or the mounted path's folder) are printed. ParaAir's own caches drop each
            path before its line is printed; macOS may still show a mounted file's old contents for a while (on
            macOS 26 until the drive is mounted again).
            Offline or busy service: once following, --follow waits and goes on; without --since, failing to get the
            first cursor ends it.
            """ + "\n"
        case "access":
            return """
            Usage: paraair access list (PROFILE [FOLDER] | MOUNTED_PATH) [--json]
                   paraair access set (PROFILE FOLDER | MOUNTED_PATH) (--email E | --role members|viewers | --credential ID)
                                      --level none|read|create|write [--json]
                   paraair access remove (PROFILE FOLDER | MOUNTED_PATH) (--email E | --role members|viewers | --credential ID) [--json]
            Folder rules of a ParaAir Cloud drive, for its workspace's owners and admins (exit 12 otherwise).
            list shows the rules on, above and inside FOLDER (all with /). create lets someone add files and
            folders and change only what they wrote, without moving or deleting anything. The most specific rule
            wins; owners and admins are never limited. --credential takes a service credential's id (see credentials);
            a credential sees only the folders its own rules give it.
            """ + "\n"
        case "credentials":
            return """
            Usage: paraair credentials create --cloud-account ID --workspace WS --name NAME [--json]
                   paraair credentials list --cloud-account ID --workspace WS [--json]
                   paraair credentials revoke --cloud-account ID --workspace WS --id CREDENTIAL_ID [--json]
            Service credentials of a ParaAir Cloud workspace, for its owners and admins (exit 12 otherwise): a login
            for a backend, such as a job that writes one folder, that sees only the folders given to it. The workspace
            id is in cloud-drives' output.
            create prints the token, pcs_cred_….<secret>, once, on standard output ("token" with --json). It can't be
            shown again and ParaAir keeps no copy: store it in the backend's secret store, or revoke the credential
            and create another if it is lost. A new credential sees nothing until a folder rule names it:
              paraair access set PROFILE /admin/finance --credential CREDENTIAL_ID --level write
            (--level create: read, add files and folders, change only what it wrote, move or delete nothing).
            list shows each credential's id, state, last use and name, never the token. revoke stops the token at once
            and deletes the credential's folder rules in every drive of the workspace.
            At most 20 active credentials per workspace. Exit 14 when the account isn't in the workspace, 17 when the
            workspace has no credential with that id.
            """ + "\n"
        case "members":
            return """
            Usage: paraair members list --cloud-account ID --workspace WS [--json]
                   paraair members add --cloud-account ID --workspace WS --email E [--role owner|admin|member|viewer]
                                       [--notify] [--json]
                   paraair members role --cloud-account ID --workspace WS --email E --role owner|admin|member|viewer [--json]
                   paraair members remove --cloud-account ID --workspace WS --email E [--json]
            A ParaAir Cloud workspace's members, for its owners and admins (exit 12 otherwise; 14 when the account
            isn't in the workspace). WS is the workspaceId cloud-drives shows. list prints the seats used, then
            user id, role, status and email per member; status is active (signed in since being added), invited
            (not yet) or disabled. add makes a member right away (role member unless --role); an address without an
            account gets one and can sign in with it. With --notify, ParaAir Cloud emails a newly added person an
            invitation; otherwise nothing is emailed, so tell them. add prints whether an email went out (notified
            with --json). A new member needs a free seat. Only owners make owners; admins can't change or remove an
            owner, and the last owner can't be demoted or removed. role and remove find the member by email (exit 17
            when they aren't one). A removed member loses access to the workspace's drives at once.
            """ + "\n"
        case "conflicts", "resolve":
            return """
            Usage: paraair conflicts PROFILE [--json]
                   paraair resolve PROFILE PATH --keep-mine-as NAME [--json]
                   paraair resolve PROFILE PATH --keep-theirs [--json]
                   paraair resolve PROFILE PATH --export-to FILE [--replace] [--json]
            conflicts lists changes that never upload by themselves: files that changed elsewhere
            after this Mac's copy was made, and changes storage refuses (another Mac took over the
            drive, or a read-only ParaAir Cloud plan).
            Changes refused to your ParaAir Cloud role or folder rules wait here too.
            --keep-mine-as saves this Mac's copy as a new file NAME in the same folder, which uploads;
            the original shows the version in storage. --export-to writes this Mac's copy to FILE on
            this Mac (outside the drive) and removes it from the drive, for drives that refuse new
            files. --keep-theirs deletes this Mac's copy.
            """ + "\n"
        default:
            return """
            ParaAir — streamed files in Finder
            Usage: paraair [--state-dir PATH] COMMAND [PROFILE] [options]

              connections                         List public saved connection references
              setup-status                        App, File System Extension, accounts and drives, for setup by another app
              extension-settings [--wait SECONDS] Open System Settings at File System Extensions (By Category); --wait
                                                  until ParaAir is switched on there
              cloud-sign-in [--wait SECONDS]      Open ParaAir's ParaAir Cloud sign-in; --wait until an account is signed in
              cloud-accounts                      List ParaAir Cloud accounts signed in with the app
              cloud-drives --cloud-account ID     List the account's ParaAir Cloud drives (id, workspace, name, role)
              connect PROFILE [options]           Save an existing JuiceFS volume reference
              mount PROFILE [--mount-point PATH] [--wait SECONDS]
                                                  Mount using the signed macOS filesystem extension; without a
                                                  mount point (or under /Volumes) the app mounts it at /Volumes/PROFILE
              unmount PROFILE                     Unmount without forcing open files closed
              ls PROFILE [/path]                  List metadata without hydrating file content
              reveal PROFILE [/path]              Open the mounted path in Finder
              status [PROFILE]                    Report local cache, pins, pending writes and state
              cache PROFILE [--evict] [--limit-mib N]
              pin PROFILE [/path]                 Explicitly download for offline reads
              unpin PROFILE [/path]               Make clean blocks eligible for eviction
              uploads PROFILE [--retry]           Inspect or retry durable pending uploads
              conflicts PROFILE                   List changes that wait for a decision
              resolve PROFILE PATH (--keep-mine-as NAME | --keep-theirs | --export-to FILE)
                                                  Settle one of them
              settings PROFILE [--conflict-copies on|off]
                                                  Show or change the drive's settings on this Mac
              versions TARGET [--before CURSOR]   List a file's kept versions (ParaAir Cloud)
              cat-version TARGET VERSION          Write one version's bytes to standard output
              restore-version TARGET VERSION [--expected-version VERSION]
                                                  Make an earlier version current again
              conflict-info TARGET                Where a conflict copy came from
              changes TARGET [--since CURSOR] [--follow [--push]]
                                                  The drive's change feed, as JSON lines with --json
              access list|set|remove TARGET ...   A drive's folder rules (owners and admins)
              credentials create|list|revoke --cloud-account ID --workspace WS
                                                  A workspace's service credentials (owners and admins)
              members list|add|role|remove --cloud-account ID --workspace WS ...
                                                  A workspace's members (owners and admins); add --notify emails
                                                  the invitation
              trash PROFILE                       List deleted ParaAir Cloud files that can be restored
              restore PROFILE NODE_ID [--to PATH] Restore a deleted ParaAir Cloud file
              stored-drives --connection ID       List drives backed up in a connection's bucket
              recover PROFILE --connection ID --volume NAME
                                                  Open a backed-up drive on this Mac
              doctor [PROFILE]                    Check local prerequisites without network or Keychain access
              help [COMMAND]

            TARGET is PROFILE PATH (a path in the drive, such as /projects/plan.md) or a path under a mounted drive,
            such as /Volumes/Team/projects/plan.md; the drive and its state folder are worked out from the mount.
            --json returns structured results. --profile NAME can replace a positional profile.
            State: --state-dir, then STREAMDRIVE_HOME, then ~/Library/Application Support/StreamDrive.
            The streamdrive command remains available for compatibility.
            Doctor app override: PARAAIR_APP_PATH (legacy STREAMDRIVE_APP_PATH is also supported).
            This Finder extension requires macOS 26+ and the installed, signed, enabled ParaAir app.
            Profiles contain no credentials. Sign in or enter keys in the separate Connections window.
            Untouched files are not downloaded; cache, pins, dirty writes and metadata are accounted separately.
            Exit codes: 0 success, 1 operation failed, 2 usage error, 3 uploads remain after retry, 10 the app isn't
            installed, 11 not signed in to ParaAir Cloud, 12 the account's role doesn't allow it, 13 the File System
            Extension isn't turned on, 14 no such ParaAir Cloud drive or workspace, 15 the path isn't on a mounted
            ParaAir drive, 16 the file changed since the expected version, 17 no such file, version, conflict copy,
            service credential or member. With --json an error prints {"error", "exitCode", "code"}; code is failed,
            usage, app_not_installed, not_signed_in, forbidden, extension_disabled, drive_not_found, not_mounted,
            version_conflict or not_found.
            """ + "\n"
        }
    }
}
