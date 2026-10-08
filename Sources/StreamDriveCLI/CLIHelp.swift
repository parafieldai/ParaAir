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
              --credential-id ID     Metadata URI stored by the app's secure Keychain dialog
              --mount-point PATH     Empty directory for the Finder volume
              --cache-mib N          Evictable touched-block cache limit (default 1024 MiB)
              --min-free-mib N       Free-space reserve (default 5120 MiB)
              --block-size N         Read/cache block size in bytes (4096–8388608; default 1048576)
              --journal-mib N        Pending-write admission limit (default 4096 MiB)
              --replace             Explicitly replace an unmounted profile configuration
              --fixture-root PATH   Explicit local-directory test adapter; never a remote fallback

            connect saves a reference. It does not format storage, test connectivity or mount it.
            Create new managed cloud volumes in the Mac app. --connection selects its saved authorization.
            Secret URLs are entered through the app's secure dialog and stored in Keychain.
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
            Conflicts remain retained for manual resolution; exit 3 means records remain after retry.
            """ + "\n"
        default:
            return """
            ParaAir — streamed files in Finder
            Usage: paraair [--state-dir PATH] COMMAND [PROFILE] [options]

              connections                         List public saved connection references
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
