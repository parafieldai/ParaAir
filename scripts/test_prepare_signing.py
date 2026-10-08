import datetime as dt
import hashlib
import importlib.util
import pathlib
import plistlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("prepare-signing.py")
NOW = dt.datetime(2026, 10, 2, tzinfo=dt.timezone.utc)
TEAM = "ABCDEFGHIJ"
PREFIX = "ZYXWVUTSRQ"
CERTIFICATE = b"synthetic public certificate fixture"
IDENTITY = hashlib.sha1(CERTIFICATE).hexdigest().upper()
GROUP = TEAM + ".dev.streamdrive.credentials"


def profile(bundle="dev.streamdrive.app", extension=False):
    entitlements = {
        "com.apple.application-identifier": PREFIX + "." + bundle,
        "com.apple.developer.team-identifier": TEAM,
        "keychain-access-groups": [TEAM + ".*"],
    }
    if extension:
        entitlements["com.apple.developer.fskit.fsmodule"] = True
    return {
        "UUID": "synthetic-profile",
        "Platform": ["OSX"],
        "ExpirationDate": NOW + dt.timedelta(days=30),
        "CreationDate": NOW - dt.timedelta(days=1),
        "ProvisionsAllDevices": True,
        "ApplicationIdentifierPrefix": [PREFIX],
        "TeamIdentifier": [TEAM],
        "DeveloperCertificates": [CERTIFICATE],
        "Entitlements": entitlements,
    }


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), "provisioning preflight is not implemented")
        spec = importlib.util.spec_from_file_location("prepare_signing", SCRIPT)
        self.signing = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.signing)

    def validate(self, value=None, bundle="dev.streamdrive.app", extension=False):
        return self.signing.validate_profile(
            profile() if value is None else value,
            bundle_id=bundle, team_id=TEAM, identity_sha1=IDENTITY,
            now=NOW, require_fskit=extension,
        )

    def test_prefix_is_taken_from_profile_not_team_id(self):
        valid = self.validate()
        self.assertEqual(valid["application_identifier"], PREFIX + ".dev.streamdrive.app")
        self.assertEqual(valid["keychain_group"], GROUP)

    def test_identity_must_be_explicit_certificate_sha1(self):
        with self.assertRaisesRegex(ValueError, "SHA-1"):
            self.signing.validate_profile(profile(), bundle_id="dev.streamdrive.app",
                team_id=TEAM, identity_sha1="Developer ID Application: Example", now=NOW)

    def test_profile_rejects_wrong_platform_expiry_team_and_certificate(self):
        changes = [
            ("Platform", ["iOS"]),
            ("ExpirationDate", NOW),
            ("CreationDate", NOW + dt.timedelta(minutes=5)),
            ("ProvisionsAllDevices", False),
            ("TeamIdentifier", ["OTHERTEAM01"]),
            ("DeveloperCertificates", [b"another certificate"]),
        ]
        for field, value in changes:
            with self.subTest(field=field):
                candidate = profile()
                candidate[field] = value
                with self.assertRaises(ValueError):
                    self.validate(candidate)

    def test_wildcard_application_identifier_and_conflicting_alias_fail(self):
        for identifier in (PREFIX + ".*", TEAM + ".dev.streamdrive.app"):
            candidate = profile()
            candidate["Entitlements"]["com.apple.application-identifier"] = identifier
            with self.assertRaises(ValueError):
                self.validate(candidate)
        candidate = profile()
        candidate["Entitlements"]["application-identifier"] = "unexpected.other"
        with self.assertRaises(ValueError):
            self.validate(candidate)

    def test_group_requires_profile_allowlist(self):
        candidate = profile()
        candidate["Entitlements"]["keychain-access-groups"] = [PREFIX + ".*"]
        with self.assertRaisesRegex(ValueError, "Keychain"):
            self.validate(candidate)
        candidate["Entitlements"]["keychain-access-groups"] = [GROUP]
        self.assertEqual(self.validate(candidate)["keychain_group"], GROUP)

    def test_extension_requires_fskit_authorization(self):
        bundle = "dev.streamdrive.app.filesystem"
        candidate = profile(bundle)
        with self.assertRaisesRegex(ValueError, "FSKit"):
            self.validate(candidate, bundle=bundle, extension=True)
        candidate["Entitlements"]["com.apple.developer.fskit.fsmodule"] = True
        self.assertEqual(self.validate(candidate, bundle=bundle, extension=True)["bundle_id"], bundle)

    def test_native_mounter_requires_exact_profile_grant(self):
        for grant in (None, False, "true"):
            candidate = profile()
            candidate["Entitlements"]["com.apple.developer.fskit.mount"] = grant
            with self.subTest(grant=grant), self.assertRaisesRegex(ValueError, "FSKit Mounter"):
                self.signing.validate_profile(candidate, bundle_id="dev.streamdrive.app",
                    team_id=TEAM, identity_sha1=IDENTITY, now=NOW, require_mounter=True)
        candidate["Entitlements"]["com.apple.developer.fskit.mount"] = True
        self.signing.validate_profile(candidate, bundle_id="dev.streamdrive.app",
            team_id=TEAM, identity_sha1=IDENTITY, now=NOW, require_mounter=True)

    def test_minimal_entitlements_do_not_copy_profile_capabilities(self):
        candidate = profile()
        candidate["Entitlements"]["com.apple.developer.icloud-services"] = ["CloudDocuments"]
        valid = self.validate(candidate)
        result = self.signing.signing_entitlements({}, valid)
        self.assertEqual(result, {
            "com.apple.application-identifier": PREFIX + ".dev.streamdrive.app",
            "com.apple.developer.team-identifier": TEAM,
            "keychain-access-groups": [GROUP],
        })

    def test_developer_id_profile_must_not_allow_debugging(self):
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            candidate = profile()
            candidate["Entitlements"][key] = True
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "debugging"):
                self.validate(candidate)

    def test_extension_entitlements_retain_only_project_sandbox_requirements(self):
        root = SCRIPT.parent.parent
        template = plistlib.loads((root / "macOS/Extension/StreamDriveFS.entitlements").read_bytes())
        valid = self.validate(profile("dev.streamdrive.app.filesystem", extension=True),
            bundle="dev.streamdrive.app.filesystem", extension=True)
        result = self.signing.signing_entitlements(template, valid)
        self.assertTrue(result["com.apple.security.app-sandbox"])
        self.assertTrue(result["com.apple.developer.fskit.fsmodule"])
        self.assertEqual(result["keychain-access-groups"], [GROUP])

    def test_adhoc_packaging_removes_previous_profiles_and_shared_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "ParaAir.app"
            contents = bundle / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "dev.streamdrive.app",
                "ParaAirKeychainAccessGroup": GROUP,
            }))
            (contents / "embedded.provisionprofile").write_bytes(b"previous profile")
            self.signing.configure_bundle_security(bundle)
            info = plistlib.loads((contents / "Info.plist").read_bytes())
            self.assertNotIn("ParaAirKeychainAccessGroup", info)
            self.assertFalse((contents / "embedded.provisionprofile").exists())

    def test_signed_packaging_embeds_matching_profile_and_group(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "ParaAirCLI.app"
            contents = bundle / "Contents"
            contents.mkdir(parents=True)
            info_path = contents / "Info.plist"
            info_path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.streamdrive.app.cli"}))
            source = pathlib.Path(directory) / "cli.provisionprofile"
            source.write_bytes(b"validated public profile")
            self.signing.configure_bundle_security(bundle, group=GROUP, profile_path=source)
            self.assertEqual(plistlib.loads(info_path.read_bytes())["ParaAirKeychainAccessGroup"], GROUP)
            self.assertEqual((contents / "embedded.provisionprofile").read_bytes(), source.read_bytes())

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS Foundation")
    def test_compatibility_launcher_resolves_cli_bundle_and_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            helpers = root / "ParaAir.app/Contents/Helpers"
            cli = helpers / "ParaAirCLI.app"
            executable = cli / "Contents/MacOS/paraair"
            executable.parent.mkdir(parents=True)
            info = plistlib.loads((SCRIPT.parent.parent / "macOS/CLI/Info.plist").read_bytes())
            info["ParaAirKeychainAccessGroup"] = GROUP
            (cli / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            source = root / "bundle-probe.swift"
            source.write_text('''import Foundation
let report = ["identifier": Bundle.main.bundleIdentifier ?? "missing",
              "group": Bundle.main.object(forInfoDictionaryKey: "ParaAirKeychainAccessGroup") as? String ?? "missing"]
let data = try JSONSerialization.data(withJSONObject: report)
print(String(decoding: data, as: UTF8.self))
''')
            build = subprocess.run(["xcrun", "swiftc", "-module-cache-path",
                str(SCRIPT.parent.parent / ".build/xcode/ModuleCache.noindex"),
                str(source), "-o", str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stderr)
            shortcut = helpers / "paraair"
            launcher_source = SCRIPT.parent / "cli-launcher.c"
            self.assertTrue(launcher_source.exists(), "native CLI compatibility launcher is missing")
            build = subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror",
                str(launcher_source), "-o", str(shortcut)], capture_output=True, text=True, timeout=30)
            self.assertEqual(build.returncode, 0, build.stderr)
            installed_alias = root / "paraair-installed-alias"
            installed_alias.symlink_to(shortcut)
            for invocation in (executable, shortcut, installed_alias):
                result = subprocess.run([str(invocation)], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {
                    "identifier": "dev.streamdrive.app.cli", "group": GROUP,
                }, str(invocation))


if __name__ == "__main__":
    unittest.main()
