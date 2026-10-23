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
              --credential-id ID     Metadata URI stored by the app's secure Keychain dialog
              --mount-point PATH     Empty directory for the Finder volume
              --cache-mib N          Evictable touched-block cache limit (default 1024 MiB)
              --min-free-mib N       Free-space reserve (default 5120 MiB)
              --block-size N         Read/cache block size in bytes (4096–8388608; default 1048576,
                                     4194304 with --connection; ParaAir Cloud requires 4194304)
              --journal-mib N        Pending-write admission limit (default 4096 MiB)
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
        case "conflicts", "resolve":
            return """
            Usage: paraair conflicts PROFILE [--json]
                   paraair resolve PROFILE PATH --keep-mine-as NAME [--json]
                   paraair resolve PROFILE PATH --keep-theirs [--json]
                   paraair resolve PROFILE PATH --export-to FILE [--replace] [--json]
            conflicts lists changes that never upload by themselves: files that changed elsewhere
            after this Mac's copy was made, and changes storage refuses (another Mac took over the
            drive, or a read-only ParaAir Cloud plan).
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
              cloud-accounts                      List ParaAir Cloud accounts signed in with the app
              connect PROFILE [options]           Save an existing JuiceFS volume reference
              mount PROFILE [--mount-point PATH]  Mount using the signed macOS filesystem extension
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
              trash PROFILE                       List deleted ParaAir Cloud files that can be restored
              restore PROFILE NODE_ID [--to PATH] Restore a deleted ParaAir Cloud file
              stored-drives --connection ID       List drives backed up in a connection's bucket
              recover PROFILE --connection ID --volume NAME
                                                  Open a backed-up drive on this Mac
              doctor [PROFILE]                    Check local prerequisites without network or Keychain access
              help [COMMAND]

            --json returns structured results. --profile NAME can replace a positional profile.
            State: --state-dir, then STREAMDRIVE_HOME, then ~/Library/Application Support/StreamDrive.
            The streamdrive command remains available for compatibility.
            Doctor app override: PARAAIR_APP_PATH (legacy STREAMDRIVE_APP_PATH is also supported).
            This Finder extension requires macOS 26+ and the installed, signed, enabled ParaAir app.
            Profiles contain no credentials. Sign in or enter keys in the separate Connections window.
            Untouched files are not downloaded; cache, pins, dirty writes and metadata are accounted separately.
            Exit codes: 0 success, 1 operation failed, 2 usage error, 3 uploads remain after retry.
            """ + "\n"
        }
    }
}
