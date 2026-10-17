#!/usr/bin/env python3
"""Regression checks for the signing gate; no signing or account changes."""
import contextlib
import datetime
import io
from pathlib import Path
import plistlib
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import verify_signing_identity as signing


class SigningIdentityTests(unittest.TestCase):
    def test_installer_restores_previous_bundle_when_final_verification_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "Scripts"
            scripts.mkdir()
            destination = root / "Installed.app"
            destination.mkdir()
            (destination / "old-marker").touch()
            candidate = root / "Candidate.app"
            candidate.mkdir()
            (candidate / "new-marker").touch()
            source = Path(__file__).with_name("install_development.sh").read_text()
            source = source.replace("DESTINATION=/Applications/ClickMate.app", f'DESTINATION="{destination}"')
            source = source.replace("mktemp -d /Applications/.ClickMate-install.XXXXXX", f'mktemp -d "{root}/.ClickMate-install.XXXXXX"')
            installer = scripts / "install_development.sh"
            installer.write_text(source)
            (scripts / "verify_signing_identity.py").write_text(
                "import sys\n" + f"sys.exit(1 if sys.argv[1] == 'verify' and sys.argv[2] == {str(destination)!r} else 0)\n"
            )
            fake_commands = root / "bin"
            fake_commands.mkdir()
            codesign = fake_commands / "codesign"
            codesign.write_text("#!/bin/sh\necho 'Signature=adhoc' >&2\n")
            codesign.chmod(0o755)
            environment = dict(os.environ, PATH=str(fake_commands) + ":" + os.environ["PATH"])
            result = subprocess.run(["/bin/bash", str(installer), str(candidate)], env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((destination / "old-marker").exists(), result.stdout + result.stderr)
            self.assertFalse((destination / "new-marker").exists())
            self.assertEqual(list(root.glob(".ClickMate-install.*")), [])

    def test_certificate_team_comes_from_subject_ou(self):
        certificate = b"certificate-der"
        fingerprint = signing.hashlib.sha1(certificate).hexdigest().upper()
        def command(*args, data=None):
            if args[1] == "find-identity":
                return f'1) {fingerprint} "Apple Development: Example (P447BJ5L92)"'.encode()
            if args[1] == "find-certificate":
                return b"-----BEGIN CERTIFICATE-----test-----END CERTIFICATE-----"
            if "-outform" in args:
                return certificate
            return b"subject=\n organizationalUnitName = AA8ZVDT74G\n"
        with patch.object(signing, "run", side_effect=command):
            self.assertEqual(signing.resolve_identity()[1], "AA8ZVDT74G")
            with self.assertRaisesRegex(ValueError, "differs from certificate subject.OU"):
                signing.resolve_identity(expected_team="P447BJ5L92")

    def test_embedded_profile_checks_platform_certificate_and_expiry(self):
        certificate = b"profile-certificate"
        fingerprint = signing.hashlib.sha1(certificate).hexdigest().upper()
        profile_override = {}
        def command(*args, data=None):
            if args[0] == "/usr/bin/codesign" and "--entitlements" in args:
                bundle_id = plistlib.loads((Path(args[-1]) / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
                return plistlib.dumps({"com.apple.application-identifier": f"AA8ZVDT74G.{bundle_id}",
                                      "com.apple.developer.team-identifier": "AA8ZVDT74G",
                                      "com.apple.security.application-groups": [signing.GROUP]})
            if args[0] == "/usr/bin/security":
                bundle_id = plistlib.loads((Path(args[-1]).parent / "Info.plist").read_bytes())["CFBundleIdentifier"]
                profile = {"TeamIdentifier": ["AA8ZVDT74G"], "Platform": ["OSX"], "DeveloperCertificates": [certificate],
                           "Entitlements": {"com.apple.application-identifier": f"AA8ZVDT74G.{bundle_id}",
                                            "com.apple.developer.team-identifier": "AA8ZVDT74G",
                                            "com.apple.security.application-groups": [signing.GROUP]},
                           "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=30)}
                profile.update(profile_override)
                return plistlib.dumps(profile)
            return b""
        details = "Authority=Apple Development: Example\nTeamIdentifier=AA8ZVDT74G\nflags=0x10000(runtime)\n"
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            for relative, bundle_id, grouped in signing.COMPONENTS:
                contents = app / relative / "Contents"
                contents.mkdir(parents=True, exist_ok=True)
                (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id,
                    "CFBundleShortVersionString": "1", "CFBundleVersion": "1"}))
                if grouped:
                    (contents / "embedded.provisionprofile").touch()
            with patch.object(signing, "run", side_effect=command), \
                 patch.object(signing, "signature", return_value=details), \
                 patch.object(signing, "requirement", return_value='identifier "test"'), \
                 patch.object(signing, "certificate_fingerprint", return_value=fingerprint):
                self.assertEqual(signing.verify(app, expected_certificate=fingerprint), "AA8ZVDT74G")
                for override, message in (({"Platform": ["iOS"]}, "does not authorize macOS"),
                        ({"DeveloperCertificates": [b"other"]}, "actual signing certificate"),
                        ({"ExpirationDate": datetime.datetime(2000, 1, 1)}, "has expired")):
                    with self.subTest(message=message):
                        profile_override.clear()
                        profile_override.update(override)
                        with self.assertRaisesRegex(ValueError, message):
                            signing.verify(app)

    def test_adhoc_requirement_cannot_be_used_as_upgrade_identity(self):
        with patch.object(signing, "signature", return_value='Signature=adhoc\n# designated => cdhash H"123"'):
            with self.assertRaisesRegex(ValueError, "no stable designated requirement"):
                signing.requirement(Path("/candidate"))

    def test_changed_code_is_checked_against_both_requirements_for_every_component(self):
        def details(path):
            return "CDHash=" + ("old" if str(path).startswith("/previous") else "new") + "\n"
        with patch.object(signing, "verify", return_value="AA8ZVDT74G"), patch.object(signing, "verify_previous_identity"), \
             patch.object(signing, "requirement", side_effect=lambda path: 'identifier "' + str(path) + '"'), \
             patch.object(signing, "signature", side_effect=details), \
             patch.object(signing, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            signing.compare("/previous", "/candidate", require_code_change=True)
            self.assertEqual(run.call_count, 6)
            for index in range(0, 6, 2):
                forward = run.call_args_list[index].args
                backward = run.call_args_list[index + 1].args
                self.assertIn("/previous", forward[-2])
                self.assertTrue(forward[-1].startswith("/candidate"))
                self.assertIn("/candidate", backward[-2])
                self.assertTrue(backward[-1].startswith("/previous"))

    def test_unchanged_build_does_not_prove_changed_code_acceptance(self):
        with patch.object(signing, "verify", return_value="AA8ZVDT74G"), patch.object(signing, "verify_previous_identity"), \
             patch.object(signing, "requirement", return_value='identifier "test"'), \
             patch.object(signing, "signature", return_value="CDHash=same\n"), patch.object(signing, "run"):
            with self.assertRaisesRegex(ValueError, "Code hashes did not change"):
                signing.compare("/previous", "/candidate", require_code_change=True)

    def test_incompatible_requirement_aborts_comparison(self):
        with patch.object(signing, "verify", return_value="AA8ZVDT74G"), patch.object(signing, "verify_previous_identity"), \
             patch.object(signing, "requirement", return_value='identifier "test"'), \
             patch.object(signing, "run", side_effect=ValueError("requirement rejected")):
            with self.assertRaisesRegex(ValueError, "requirement rejected"):
                signing.compare("/previous", "/candidate")

    def test_wildcard_profile_cannot_enable_app_group_development(self):
        profile = {
            "TeamIdentifier": ["AA8ZVDT74G"], "Platform": ["OSX"],
            "Entitlements": {"com.apple.application-identifier": "AA8ZVDT74G.*"},
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=30),
        }
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            profiles = home / "Library/Developer/Xcode/UserData/Provisioning Profiles"
            profiles.mkdir(parents=True)
            (profiles / "wildcard.provisionprofile").touch()
            with patch.object(Path, "home", return_value=home), patch.object(signing, "run", return_value=plistlib.dumps(profile)):
                with self.assertRaisesRegex(ValueError, "Missing valid macOS development profiles"):
                    signing.verify_local_profiles("AA8ZVDT74G", "A" * 40)

    def test_explicit_profiles_require_the_selected_certificate(self):
        certificate = b"public-certificate"
        fingerprint = signing.hashlib.sha1(certificate).hexdigest().upper()
        profile_by_name = {}
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            profiles = home / "Library/Developer/Xcode/UserData/Provisioning Profiles"
            profiles.mkdir(parents=True)
            for index, (_, bundle_id, grouped) in enumerate(signing.COMPONENTS):
                if not grouped:
                    continue
                path = profiles / f"{index}.provisionprofile"
                path.touch()
                profile_by_name[str(path)] = plistlib.dumps({
                    "TeamIdentifier": ["AA8ZVDT74G"], "Platform": ["OSX"],
                    "DeveloperCertificates": [certificate],
                    "Entitlements": {"com.apple.application-identifier": f"AA8ZVDT74G.{bundle_id}", "com.apple.security.application-groups": [signing.GROUP]},
                    "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=30),
                })
            with patch.object(Path, "home", return_value=home), \
                 patch.object(signing, "run", side_effect=lambda *args: profile_by_name[args[-1]]), \
                 contextlib.redirect_stdout(io.StringIO()):
                signing.verify_local_profiles("AA8ZVDT74G", fingerprint)
                with self.assertRaisesRegex(ValueError, "Missing valid macOS development profiles"):
                    signing.verify_local_profiles("AA8ZVDT74G", "B" * 40)


if __name__ == "__main__":
    unittest.main()
