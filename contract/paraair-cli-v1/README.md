# ParaAir CLI contract v1

This is what another app on the Mac may rely on when it sets up ParaAir or works with a ParaAir Cloud drive: the `paraair` command's JSON output and exit codes, two `paraair://` URLs, and the mounted drive. Builds that follow it report `"contractVersion": 1` in `paraair setup-status --json`.

The shapes below are taken from the code (`Sources/StreamDriveCLI/`, and the Core types they encode). Where this document and the code disagree, the code is wrong or this document is out of date; both are fixed in the same change.

## What an integration may use

- The `paraair` command, with `--json`, as listed here. It is in the app at `ParaAir.app/Contents/Helpers/ParaAirCLI.app/Contents/MacOS/paraair`.
- `paraair://cloud/sign-in` and `paraair://drive/mount?profile=NAME&folder=STATE_FOLDER`, opened in ParaAir. The CLI's `cloud-sign-in` and `mount` open them and wait for the result; prefer those.
- Files under the mounted drive, `/Volumes/<Finder name>/…`, read and written like any other files.
- The rights of the person who is signed in. The CLI never does more than their role and the drive's folder rules allow; folder rules can be changed only by a workspace owner or admin (`access`).

Not part of the contract, and free to change in any release: the files in a state folder (profiles, account records, caches, journals), the Keychain items, the app's settings (`selectedStateRoot`, `knownStateRoots`), the ParaAir Cloud service API (that is [`contract/paraair-cloud-v1/`](../paraair-cloud-v1/), between the service and the Mac client), output without `--json`, help text, the wording of `error` messages, and every command, option or field not listed here.

## Versions and compatibility

- `setup-status --json` reports `contractVersion`, a number. Gate on it, not on the app's `build`. A build without the field predates this contract: treat it as version 0 and rely on nothing here.
- Within v1 only additive changes are made: new commands, new options, new JSON fields, new exit codes and `code` values, and new values in the string sets this document calls open.
- Renaming or removing a command, option, field, exit code or `code`, changing a field's type, or changing what an existing value means, is a new version: `contractVersion: 2`, described in `contract/paraair-cli-v2/`.

So an integration should:

- ignore JSON fields it doesn't know;
- not depend on key order, indentation or line breaks inside an object (single objects are printed indented today; `changes` prints one compact object per line);
- treat any non-zero exit as failure, and act on the exit codes and `code` values it knows;
- handle an unknown value in an open set as the section says.

## Conventions

- `--json` can go anywhere on the command line. Success: the result is written to standard output, exit 0. Failure: see [Errors](#errors).
- Global options: `--state-dir PATH` picks a state folder (else `STREAMDRIVE_HOME`, else the default `~/Library/Application Support/StreamDrive`). `--profile NAME` can replace a positional profile.
- A state folder holds one drive. `setup-status`, `cloud-sign-in` and `cloud-drives` look in the default folder, every folder the app remembers and the folders under `~/Library/Application Support/ParaAir/Cloud Drives/`; `--state-dir` (or `STREAMDRIVE_HOME`) narrows them to one. Commands that name a `PROFILE` look in the one folder `--state-dir` selects, so pass the `stateDirectory` that `setup-status` or `connect` printed.
- `PROFILE` is 1–64 letters, digits, `.`, `_` or `-`, starting with a letter or digit.
- Drive paths start with `/`, as in `/projects/plan.md`, and are case-sensitive.
- `TARGET` is `PROFILE PATH` (a drive path) or one path under a mounted drive, such as `/Volumes/Team/projects/plan.md`. For a mounted path the CLI finds the mounted ParaAir volume that contains it, then the profile mounted there in the known state folders (or the profile named like the volume that has no mount point saved); `--state-dir` narrows the search. Exit 15 when there is none.
- Times (`createdAt`, `expiresAt`, `at`, `updatedAt`) are RFC 3339 strings. Those from the service are passed on unchanged; `conflict-info` writes `createdAt` itself for a copy saved on this Mac. Versions are `pv:` and a positive integer (`pv:123`). Cursors are integers below 2^53.
- In the shapes below, `field?` may be absent, and `T | null` is always present but may be `null`.

## Setup

### `setup-status`

`paraair setup-status --json`. Local only: no network, nothing opened.

```
{
  "contractVersion": 1,
  "app": {"installed": bool, "path"?: string, "running": bool, "version"?: string, "build"?: string},
  "extension": {"state": string, "otherCopies": [string]},
  "accounts": [{"id": string, "email": string, "issuer": string, "state": string,
                "stateDirectory": string, "workspaceIds": [string]}],
  "profiles": [{"profile": string, "stateDirectory": string, "backend": string,
                "cloudAccountId"?: string, "cloudDriveId"?: string, "workspaceId"?: string,
                "mountPoint"?: string, "mounted": bool, "healthy": bool,
                "conflictCopies": bool, "knownToApp": bool}]
}
```

- `app.path` is present when the app is installed. `build` is CFBundleVersion, which grows with every release; `version` is CFBundleShortVersionString.
- `extension.state` (open set): `enabled`, `disabled`, `notDiscovered` (also when the app isn't installed), `unknown`. Treat an unknown value like `unknown`.
- `extension.otherCopies`: paths of other copies of the app that macOS has registered and that still exist (a download, a backup). macOS can switch on the wrong copy's extension, so ask the person to keep only the installed one. Empty when there are none or the app isn't installed.
- `accounts[].state`: `signedIn` or `signedOut`. `workspaceIds` come from drives attached on this Mac; `cloud-drives` asks the service.
- `profiles[].backend` (open set): `paraairCloud`, `juicefs`, `local`. Integrations work with `paraairCloud`.
- `healthy`: mounted, no uploads that keep failing, and not in use on another Mac. Connectivity isn't read here.
- `knownToApp`: the app has learned this state folder and keeps its sign-in renewed. It doesn't mean the drive mounts by itself: the app mounts drives when it opens only while the person's **Mount when ParaAir opens** setting is on, which isn't reported here. Use `mount` to mount it now. A mount request teaches the app a folder `connect --new-state-folder` made.

### `extension-settings`

`paraair extension-settings [--wait SECONDS] --json` (`--wait` 1–900) → `{"state": string, "opened": bool}`

- Exit 10 first if the app isn't installed.
- If ParaAir's File System Extension is already on: `{"state": "enabled", "opened": false}`, and nothing is opened.
- Otherwise opens System Settings at the File System Extensions list, where the person switches ParaAir on. Without `--wait`: the state read right after (same values as `extension.state`) and `"opened": true`. With `--wait`: `{"state": "enabled", "opened": true}` once it is on, or exit 13 when the time runs out.

### `cloud-sign-in`

`paraair cloud-sign-in [--wait SECONDS] --json` (`--wait` 1–900).

- Exit 10 first if the app isn't installed.
- If an account is already signed in, prints it at once, in the shape of a `setup-status` `accounts` entry, and opens nothing.
- Otherwise opens `paraair://cloud/sign-in` (ParaAir's own sign-in; the person types the code in their browser). Without `--wait`: `{"opened": true}`. With `--wait`: the account once one is signed in, or exit 11 when the time runs out.

### `cloud-drives`

`paraair cloud-drives --cloud-account ID --json` → `[{"id": string, "workspaceId": string, "name": string, "role": string, "writable": bool}]`

Asks the service. `role` (open set) is the account's role in the drive's workspace: `owner`, `admin`, `member`, `viewer`. Exit 11 when the account isn't signed in on this Mac.

### `connect`

```
paraair [--state-dir DIR] connect PROFILE --cloud-account ID (--cloud-drive ID | --cloud-drive-name NAME)
        [--new-state-folder] [--conflict-copies] [--mount-point PATH]
        [--cache-mib N] [--min-free-mib N] [--journal-mib N] [--replace] --json
```

→ `{"profile": string, "backend": "paraairCloud", "mountPoint"?: string, "mounted": false, "stateDirectory": string}`

- Saves a ParaAir Cloud drive in a state folder after checking it with the service. It doesn't mount it.
- `--cloud-account` and `--cloud-drive` take lowercase ids. `--cloud-drive-name` matches the drive's exact name (Unicode-normalized); exit 14 when no drive or more than one has that name.
- Without `--new-state-folder`, the state folder is the one `--state-dir` selects. It must be the folder the account is signed in to (the account's `stateDirectory` in `setup-status`); otherwise `--cloud-drive-name` exits 11 and `--cloud-drive` exits 1. It must not hold another drive (exit 1).
- `--new-state-folder` attaches the drive in a new folder, `~/Library/Application Support/ParaAir/Cloud Drives/<uuid>/`, sharing the sign-in of whichever known folder the account is in. Use it for a second drive of an account whose folder already holds one. `stateDirectory` is the new folder: pass it as `--state-dir` to `mount` and the other commands. A profile name already used in another known folder is refused with exit 1 (both would mount at the same `/Volumes` point). Not with `--replace`.
- `--conflict-copies` turns on conflict copies for this drive (see [`settings`](#settings)).
- `--replace` replaces an unmounted profile of the same name; without it an existing profile is exit 1.
- Leave `--mount-point` out for a drive the app mounts at `/Volumes` (see `mount`).
- Exit 11 when the account isn't signed in, 12 when its role or workspace doesn't allow it, 14 when there is no such drive.

### `mount`

`paraair [--state-dir DIR] mount PROFILE [--wait SECONDS] --json` (`--wait` 1–900, default 90)

→ `{"profile": string, "backend": string, "mountPoint": "/Volumes/<Finder name>", "mounted": true}`

- With no mount point (none passed and none saved by `connect --mount-point`), or `/Volumes/<Finder name>`, the CLI asks the app to mount the drive through FSKit, by opening `paraair://drive/mount?profile=NAME&folder=STATE_FOLDER`, and waits until the volume is up and the app has saved that mount point to the profile. The Finder name is the drive's display name, else the profile name.
- The app mounts only a drive saved in a state folder it knows, or one it can learn (a folder of this user directly in "Cloud Drives", holding one ParaAir Cloud drive of an account already signed in to the app).
- `mount` needs macOS 26 (exit 1 at once on older systems). The app mounts at `/Volumes` through FSKit only on macOS 27 with a build that has FSKit's mount entitlement; where it can't, the wait runs out (exit 1).
- Exit 10 when the app isn't installed, 13 when its File System Extension isn't turned on, 2 for another mount point under `/Volumes`, 1 when the drive is already mounted, another volume is at that point, or the mount doesn't finish in time.

### `paraair://` URLs

The app handles these and answers nothing; a request it can't act on is ignored. Use the CLI commands above when you need the outcome.

- `paraair://cloud/sign-in`: opens ParaAir's ParaAir Cloud sign-in.
- `paraair://drive/mount?profile=NAME&folder=STATE_FOLDER`: mounts that saved drive, as the Connect button does.

## Shared drives

These work on ParaAir Cloud drives (`versions`, `cat-version`, `restore-version`, `changes` and `access` exit 2 for other drives).

### `settings`

`paraair settings PROFILE [--conflict-copies on|off] --json` → `{"profile": string, "conflictCopies": bool, "mounted": bool, "appliesAtNextMount": bool}`

With conflict copies on, when this Mac's save of a file meets a newer version from another device, the path keeps that version and this Mac's change is saved beside it as `<stem> (conflict YYYY-MM-DD).<ext>` (this Mac's local date; then `<stem> (conflict YYYY-MM-DD 2).<ext>`, and so on), which uploads like a new file. Nothing is merged. Off by default; with it off, such a change waits in `conflicts`. A mounted drive takes a change at its next mount: `appliesAtNextMount` is true when `--conflict-copies` was given while the drive is mounted. Use `conflict-info` to recognize a copy; don't parse its name.

### `versions`

`paraair versions TARGET [--before CURSOR] [--limit N] --json` (`--limit` 1–1000, default 100)

```
{"path": string,
 "versions": [{"version": string, "size": int, "createdAt": string, "author": Author,
               "current": bool, "expiresAt": string | null}],
 "nextBefore": int | null}
```

Newest first. Pass `nextBefore` as `--before` for the next page; `null` means no more. `Author` is one of:

```
{"userId": string | null, "email": string | null}                        a member
{"credential": string, "name": string | null,
 "createdBy": {"userId": string | null, "email": string | null} | null}   a service credential
```

### `cat-version`

`paraair cat-version TARGET VERSION` writes that version's bytes to standard output, unchanged. Exit 0 only when all of them were written; on any other exit, discard what was written. Exit 17 when `VERSION` isn't a kept version of this file. Without `--json` an error goes to standard error and standard output holds only file bytes; with `--json` the error object is written to standard output after any bytes, so leave `--json` off when you redirect the bytes.

### `restore-version`

`paraair restore-version TARGET VERSION [--expected-version VERSION] --json` → `{"path": string, "restoredVersion": string, "version": string, "size": int}`

The old contents become the file's new current `version`. With `--expected-version`, exit 16 (`version_conflict`) when the file's current version is another one. Exit 17 when the version is no longer kept.

### `conflict-info`

`paraair conflict-info TARGET --json`

```
{"path": string, "original": string, "baseVersion": string | null, "theirsVersion": string | null,
 "createdAt": string | null, "source": string, "author"?: Author}
```

Where a conflict copy came from. `original` is the file it was saved beside, `baseVersion` the version the losing change was based on (`null` for a file that was new on that Mac), `theirsVersion` the version it lost to. `source` (open set): `this-mac` for a copy saved here, `service` for one another Mac recorded (then with `author` when the service has one). Exit 17 when the file isn't a known conflict copy.

### `changes`

`paraair changes (PROFILE [FOLDER] | MOUNTED_PATH) [--since CURSOR] [--follow [--interval SECONDS]] --json` (`--interval` 1–300, default 3)

One compact JSON object per line, written as it comes:

- Without `--since` and `--follow`: one line, `{"cursor": N}`, the cursor to start from later.
- With `--since` alone: the changes after that cursor, then exit 0.
- With `--follow`: first `{"following": true, "cursor": N}`, N being `--since` or the current cursor; then it runs until stopped.
- Each change: `{"cursor": int, "change": string, "kind": string, "path": string, "fromPath"?: string, "rescan"?: true, "version": string | null, "at": string, "author": Author}`.
- `{"reset": true, "cursor": N}` when changes after your cursor were pruned (the feed keeps 30 days): list the folder again, then go on from N.

Tell the lines apart by their keys: `following`, `reset`, `change`, or a lone `cursor`.

- `change` (open set): `create`, `write`, `delete`, `move`, `restore`, `mkdir`, `purge`. `kind`: `file` or `directory`. `fromPath` is present for a move. `version` is `null` for deletes. `rescan: true` asks you to list that folder's subtree again. Treat an unknown `change` like `rescan` of its path's folder.
- Only changes at or under the folder (or the mounted path's folder) are printed; a move is printed when either end is there.
- Persist the `cursor` of the last line you handled and pass it as `--since` next time; the CLI keeps no cursor for you.
- Before a page is printed, ParaAir drops its own cached metadata for those paths. What macOS caches for a mounted file isn't refreshed at that moment: on macOS 27 the mounted drive reads a changed file fresh once its folder is listed again or the app's refresh marker shows the change (see [The mounted drive](#the-mounted-drive)); on macOS 26 macOS can keep a file's old size and contents until the drive is mounted again. So a read through the mount right after a line may still return the old contents. `cat-version` with the line's `version` reads exactly that version.
- Once it has printed its `following` line, `--follow` waits out being offline or a briefly unavailable service (up to a minute between tries) and goes on. Without `--since` it first asks the service for the current cursor, and a failure there, offline included, ends the command before the `following` line: start it again later, or pass the cursor you saved as `--since`, which starts following at once. Any other failure ends the command: with `--json` the error object follows the last line and may span several lines. Read lines until the process exits; on a non-zero exit, parse whatever followed the last complete line as the error object.

### `access`

```
paraair access list (PROFILE [FOLDER] | MOUNTED_PATH) --json
paraair access set (PROFILE FOLDER | MOUNTED_PATH) (--email E | --role members|viewers | --credential ID)
                   --level none|read|create|write --json
paraair access remove (PROFILE FOLDER | MOUNTED_PATH) (--email E | --role members|viewers | --credential ID) --json
```

- `list` → `{"path": string, "rules": [Rule]}`: the rules on the folder, above it and inside it (all rules for `/`).
- `set` → `{"rule": Rule}`.
- `remove` → `{"path": string, "principal": {"email": string} | {"role": string} | {"credential": string}, "removed": true}`.

`Rule` is one of:

```
{"role": string, "path": string, "access": string, "updatedAt": string}
{"credential": string, "name": string | null, "path": string, "access": string, "updatedAt": string}
{"userId": string | null, "email": string | null, "path": string, "access": string, "updatedAt": string}
```

`access` is `none`, `read`, `create` or `write`; `create` lets someone add files and folders and change only what they wrote. The most specific rule wins; owners and admins are never limited. Only a workspace owner or admin can list or change rules: exit 12 otherwise.

### `conflicts`

`paraair conflicts PROFILE --json` → the changes on this Mac that wait for a decision:

```
[{"transactionID": string, "path": string, "logicalSize": int, "pendingBytes": int, "state": string,
  "lastError"?: string, "lastErrno"?: int, "failures": int, "failingSinceNanoseconds"?: int,
  "pendingSinceNanoseconds"?: int, "modifiedNanoseconds"?: int}]
```

`state` `conflict` means the file changed elsewhere after this Mac's copy was made. Any other record was refused by storage: `lastErrno` 1 (`EPERM`) for the member's role or a folder rule, 30 (`EROFS`) for a read-only plan or a drive another Mac took over. `lastError` is text for people. `*Nanoseconds` are wall-clock times since 1970. `transactionID` is opaque.

## Errors

Exit codes:

| Exit | `code` | Meaning |
|---|---|---|
| 0 | | Success |
| 1 | `failed` | Anything not listed below |
| 2 | `usage` | Wrong command, option or value |
| 3 | | `uploads --retry` left records behind (not an error; its output is printed as usual) |
| 10 | `app_not_installed` | The ParaAir app isn't installed |
| 11 | `not_signed_in` | Not signed in to ParaAir Cloud, or the sign-in has to be renewed in the app |
| 12 | `forbidden` | The account's role or workspace doesn't allow it |
| 13 | `extension_disabled` | ParaAir's File System Extension isn't turned on |
| 14 | `drive_not_found` | No such ParaAir Cloud drive for this account |
| 15 | `not_mounted` | The path isn't on a mounted ParaAir drive, or no known profile is mounted there |
| 16 | `version_conflict` | The file's current version isn't the expected one |
| 17 | `not_found` | No such file, version or conflict copy (`versions`, `cat-version`, `restore-version`, `conflict-info`) |

11, 12 and 14 can come from any command that talks to the service. New codes may be added within v1.

With `--json`, a failure prints this to standard output, and the process exits with `exitCode`:

```
{"error": string, "exitCode": int, "code": string}
```

`error` is a message for people; act on `code` or the exit status. In the unlikely case that the CLI can't encode this object it prints `{"error": "Operation failed"}` alone; the exit status is still right. Without `--json` the message goes to standard error as `paraair: <message>`.

## The mounted drive

- A drive the app mounts is at `/Volumes/<Finder name>`; `setup-status` reports its `mountPoint`. Read and write it like any folder. Writes upload in the background; a change that can't upload waits in `conflicts`.
- While a ParaAir Cloud drive is mounted, the app follows its change feed every 3 seconds and briefly creates and removes `.paraair-refresh` in each folder that changed, so FSEvents reports the folder. Ignore that name.
- On macOS 27 a file another device changed reads as its new version once its folder is listed again or that marker appears. On macOS 26 macOS keeps a file's cached size and contents until the drive is mounted again.
