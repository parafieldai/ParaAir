#!/usr/bin/env python3
"""Validate public provisioning data before builds or any private-key operation.

The profile's diagnostic plist is checked here. Apple's signature/provisioning
enforcement still has to accept each resulting executable at launch time.
"""

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
BUNDLES = {
    "app": "dev.streamdrive.app",
    "extension": "dev.streamdrive.app.filesystem",
    "cli": "dev.streamdrive.app.cli",
}


def utc(value):
    if not isinstance(value, dt.datetime):
        raise ValueError("Provisioning profile has an invalid date")
    return value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value.astimezone(dt.timezone.utc)


def validate_profile(profile, *, bundle_id, team_id, identity_sha1, now=None, require_fskit=False, require_mounter=False):
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity_sha1):
        raise ValueError("Signing identity must be an explicit certificate SHA-1 fingerprint")
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ValueError("Invalid Apple team identifier")
    now = utc(now or dt.datetime.now(dt.timezone.utc))
    if "OSX" not in profile.get("Platform", []):
        raise ValueError("Provisioning profile must authorize macOS (OSX)")
    if utc(profile.get("ExpirationDate")) <= now:
        raise ValueError("Provisioning profile has expired")
    if utc(profile.get("CreationDate")) > now:
        raise ValueError("Provisioning profile is not yet valid")
    if profile.get("ProvisionsAllDevices") is not True or profile.get("ProvisionedDevices"):
        raise ValueError("A Developer ID distribution profile with ProvisionsAllDevices is required")
    if profile.get("TeamIdentifier") != [team_id]:
        raise ValueError("Provisioning profile belongs to a different team")
    entitlements = profile.get("Entitlements", {})
    if any(entitlements.get(key) is True for key in ("get-task-allow", "com.apple.security.get-task-allow")):
        raise ValueError("Developer ID provisioning must not allow debugging")
    if entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise ValueError("Profile entitlement team does not match the requested team")
    identifiers = [entitlements[key] for key in ("com.apple.application-identifier", "application-identifier")
                   if key in entitlements]
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    allowed = [prefix + "." + bundle_id for prefix in prefixes
               if isinstance(prefix, str) and re.fullmatch(r"[A-Z0-9]{10}", prefix)]
    if not identifiers or len(set(identifiers)) != 1 or identifiers[0] not in allowed:
        raise ValueError("Profile must contain the exact application identifier for " + bundle_id)
    certificates = profile.get("DeveloperCertificates", [])
    if not any(isinstance(cert, bytes) and hashlib.sha1(cert).hexdigest().upper() == identity_sha1.upper()
               for cert in certificates):
        raise ValueError("Signing certificate is not covered by the provisioning profile")
    group = team_id + ".dev.streamdrive.credentials"
    groups = entitlements.get("keychain-access-groups", [])
    if not any(isinstance(grant, str) and
               (grant == group or (grant.endswith(".*") and grant.count("*") == 1 and group.startswith(grant[:-1])))
               for grant in groups):
        raise ValueError("Profile does not authorize the shared ParaAir Keychain group")
    if require_fskit and entitlements.get("com.apple.developer.fskit.fsmodule") is not True:
        raise ValueError("Extension profile does not authorize the FSKit Module entitlement")
    if require_mounter and entitlements.get("com.apple.developer.fskit.mount") is not True:
        raise ValueError("Host profile does not authorize the FSKit Mounter entitlement")
    return {
        "bundle_id": bundle_id,
        "application_identifier": identifiers[0],
        "team_id": team_id,
        "keychain_group": group,
        "profile_uuid": profile.get("UUID"),
        "identity_sha1": identity_sha1.upper(),
    }


def signing_entitlements(template, validated):
    result = dict(template)
    result["com.apple.application-identifier"] = validated["application_identifier"]
    result["com.apple.developer.team-identifier"] = validated["team_id"]
    result["keychain-access-groups"] = [validated["keychain_group"]]
    return result


def configure_bundle_security(bundle, *, group=None, profile_path=None):
    if (group is None) != (profile_path is None):
        raise ValueError("Shared Keychain configuration requires a validated profile")
    contents = pathlib.Path(bundle) / "Contents"
    info_path = contents / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.pop("ParaAirKeychainAccessGroup", None)
    embedded = contents / "embedded.provisionprofile"
    if embedded.exists() or embedded.is_symlink():
        embedded.unlink()
    if group is not None:
        info["ParaAirKeychainAccessGroup"] = group
        embedded.write_bytes(pathlib.Path(profile_path).read_bytes())
        embedded.chmod(0o644)
    info_path.write_bytes(plistlib.dumps(info))


def decode_profile(source):
    # Snapshot before decoding so validation and eventual embedding use the same
    # bytes even if a user replaces the original profile during a long build.
    encoded = pathlib.Path(source).read_bytes()
    if len(encoded) > 4 * 1024 * 1024:
        raise ValueError("Provisioning profile exceeds the 4 MiB size limit")
    with tempfile.NamedTemporaryFile(suffix=".provisionprofile") as snapshot:
        snapshot.write(encoded)
        snapshot.flush()
        decoded = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", snapshot.name],
                                 capture_output=True, timeout=30)
    if decoded.returncode:
        raise ValueError("Unable to decode provisioning profile " + pathlib.Path(source).name)
    return encoded, plistlib.loads(decoded.stdout)


def preflight(arguments):
    records = {}
    snapshots = {}
    templates = {
        "app": plistlib.loads((ROOT / "macOS/App/StreamDrive.entitlements").read_bytes()),
        "extension": plistlib.loads((ROOT / "macOS/Extension/StreamDriveFS.entitlements").read_bytes()),
        "cli": {},
    }
    for role, bundle_id in BUNDLES.items():
        encoded, profile = decode_profile(getattr(arguments, role + "_profile"))
        records[role] = validate_profile(profile, bundle_id=bundle_id, team_id=arguments.team_id,
            identity_sha1=arguments.identity_sha1, require_fskit=(role == "extension"),
            require_mounter=templates[role].get("com.apple.developer.fskit.mount") is True)
        records[role]["profile_sha256"] = hashlib.sha256(encoded).hexdigest()
        snapshots[role] = encoded
    output = pathlib.Path(arguments.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    for role in BUNDLES:
        (output / (role + ".provisionprofile")).write_bytes(snapshots[role])
        (output / (role + ".entitlements")).write_bytes(plistlib.dumps(signing_entitlements(templates[role], records[role])))
    (output / "plan.json").write_text(json.dumps(records, indent=2) + "\n")
    print("Validated Developer ID provisioning for the ParaAir app, filesystem and CLI.")


def configure(arguments):
    app = pathlib.Path(arguments.app)
    bundles = {
        "app": app,
        "extension": app / "Contents/Extensions/StreamDriveFS.appex",
        "cli": app / "Contents/Helpers/ParaAirCLI.app",
    }
    plan = json.loads(pathlib.Path(arguments.plan).read_text()) if arguments.plan else None
    profiles = {}
    # Check the whole plan before modifying any bundle.
    for role, bundle in bundles.items():
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != BUNDLES[role]:
            raise ValueError("Unexpected bundle identifier for " + role)
        if plan:
            if plan[role]["bundle_id"] != BUNDLES[role]:
                raise ValueError("Signing plan does not match " + role)
            profile_path = pathlib.Path(arguments.plan).parent / (role + ".provisionprofile")
            if hashlib.sha256(profile_path.read_bytes()).hexdigest() != plan[role]["profile_sha256"]:
                raise ValueError("Validated profile snapshot changed for " + role)
            profiles[role] = profile_path
    for role, bundle in bundles.items():
        configure_bundle_security(bundle,
            group=plan[role]["keychain_group"] if plan else None,
            profile_path=profiles.get(role))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--team-id", required=True)
    validate.add_argument("--identity-sha1", required=True)
    validate.add_argument("--output-dir", required=True)
    for role in BUNDLES:
        validate.add_argument("--" + role + "-profile", required=True)
    package = commands.add_parser("configure")
    package.add_argument("--app", required=True)
    package.add_argument("--plan")
    arguments = parser.parse_args()
    try:
        preflight(arguments) if arguments.command == "validate" else configure(arguments)
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        print("Signing preflight failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
