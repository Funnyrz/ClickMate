#!/usr/bin/env python3
"""Verify ClickMate signing identities and upgrade continuity without changing TCC."""
import argparse
import datetime
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

COMPONENTS = (
    (".", "com.zxacn.clickmate", True),
    ("Contents/Library/LoginItems/ClickMateHelper.app", "com.zxacn.clickmate.Helper", False),
    ("Contents/PlugIns/ClickMateFinderExtension.appex", "com.zxacn.clickmate.FinderExtension", True),
)
GROUP = "group.com.zxacn"


def run(*args, data=None):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(f"{' '.join(map(str, args))}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def signature(bundle):
    result = subprocess.run(["/usr/bin/codesign", "-d", "-r-", "--verbose=4", str(bundle)], capture_output=True)
    details = (result.stdout + result.stderr).decode(errors="replace")
    if result.returncode:
        raise ValueError(f"Cannot read signature at {bundle}: {details.strip()}")
    return details


def field(details, key):
    match = re.search(rf"^{re.escape(key)}=(.*)$", details, re.MULTILINE)
    return match.group(1).strip() if match else ""


def requirement(bundle):
    details = signature(bundle)
    match = re.search(r"^designated => (.+)$", details, re.MULTILINE)
    if not match or "Signature=adhoc" in details or "cdhash " in match.group(1):
        raise ValueError(f"{bundle} has no stable designated requirement; ad-hoc builds cannot preserve permissions across code changes")
    return match.group(1)


def resolve_identity(selector=None, expected_team=None):
    identities = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning").decode()
    matches = re.findall(r'\) ([A-Fa-f0-9]{40}) "(Apple Development:[^"\n]+)"', identities)
    matches = [(sha.upper(), name) for sha, name in matches if not selector or selector in (name, "Apple Development") or selector.upper() == sha]
    if len(matches) != 1:
        raise ValueError("Select exactly one valid Apple Development identity with CLICKMATE_DEVELOPMENT_IDENTITY (certificate SHA-1); no ad-hoc fallback is allowed")
    sha, name = matches[0]
    certificates = run("/usr/bin/security", "find-certificate", "-a", "-p")
    for pem in re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.DOTALL):
        der = run("/usr/bin/openssl", "x509", "-outform", "DER", data=pem)
        if hashlib.sha1(der).hexdigest().upper() != sha:
            continue
        subject = run("/usr/bin/openssl", "x509", "-noout", "-subject", "-nameopt", "multiline", data=pem).decode()
        match = re.search(r"^\s*organizationalUnitName\s*=\s*([A-Z0-9]{10})\s*$", subject, re.MULTILINE)
        if not match:
            raise ValueError("Selected certificate has no Apple Team ID in subject.OU")
        team = match.group(1)
        if expected_team and expected_team != team:
            raise ValueError(f"Configured Team ID {expected_team} differs from certificate subject.OU {team}; the suffix in the display name is not the Team ID")
        return sha, team, name
    raise ValueError("Cannot locate the selected identity's public certificate in the keychain")


def verify_local_profiles(team, certificate_sha):
    directories = (
        Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
        Path.home() / "Library/MobileDevice/Provisioning Profiles",
    )
    required = {bundle_id for _, bundle_id, grouped in COMPONENTS if grouped}
    found = set()
    for directory in directories:
        for path in directory.glob("*"):
            if path.suffix not in (".provisionprofile", ".mobileprovision"):
                continue
            try:
                profile = plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i", str(path)))
                allowed = profile.get("Entitlements", {})
                app_id = allowed.get("com.apple.application-identifier", "")
                expiry = profile.get("ExpirationDate")
                certificate_hashes = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
                if (team not in profile.get("TeamIdentifier", []) or "OSX" not in profile.get("Platform", [])
                        or GROUP not in allowed.get("com.apple.security.application-groups", [])
                        or certificate_sha not in certificate_hashes or not expiry
                        or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc)):
                    continue
                for bundle_id in required:
                    if app_id == f"{team}.{bundle_id}":
                        found.add(bundle_id)
            except (ValueError, OSError, plistlib.InvalidFileException):
                continue
    missing = required - found
    if missing:
        raise ValueError(f"Missing valid macOS development profiles for {', '.join(sorted(missing))}, Team {team}, selected certificate and App Group {GROUP}. Configure explicit App IDs and the App Group in Xcode/Apple Developer, then download profiles. No ad-hoc fallback or account changes were attempted")
    print(f"Existing profiles authorize both ClickMate App IDs and {GROUP} for Team {team}")


def certificate_fingerprint(bundle):
    with tempfile.TemporaryDirectory(prefix="clickmate-public-certificates-") as directory:
        prefix = str(Path(directory) / "certificate")
        run("/usr/bin/codesign", "-d", "--extract-certificates=" + prefix, str(bundle))
        return hashlib.sha1(Path(prefix + "0").read_bytes()).hexdigest().upper()


def verify(app, expected_team=None, kind=None, expected_certificate=None):
    app = Path(app).resolve()
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    team = expected_team
    version = None
    for relative, bundle_id, group_required in COMPONENTS:
        bundle = app / relative
        with (bundle / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        if info.get("CFBundleIdentifier") != bundle_id:
            raise ValueError(f"Unexpected Bundle ID at {bundle}")
        current_version = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
        if version is not None and current_version != version:
            raise ValueError(f"Main app, Helper and Finder extension versions must match: {bundle}")
        version = current_version
        details = signature(bundle)
        requirement(bundle)
        authority = field(details, "Authority")
        if not authority.startswith(("Apple Development:", "Developer ID Application:")):
            raise ValueError(f"{bundle_id} must use an Apple Development or Developer ID Application certificate")
        if kind and not authority.startswith(kind + ":"):
            raise ValueError(f"{bundle_id} is not signed with {kind}")
        actual_team = field(details, "TeamIdentifier")
        team = team or actual_team
        if not re.fullmatch(r"[A-Z0-9]{10}", actual_team) or actual_team != team:
            raise ValueError(f"{bundle_id} has Team ID {actual_team!r}, expected {team!r}")
        if not re.search(r"flags=.*runtime", details):
            raise ValueError(f"{bundle_id} must enable hardened runtime")
        run("/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple generic", str(bundle))
        leaf_fingerprint = certificate_fingerprint(bundle)
        if expected_certificate and leaf_fingerprint != expected_certificate.upper():
            raise ValueError(f"{bundle_id} used certificate {leaf_fingerprint}, expected selected certificate {expected_certificate}")
        if not group_required:
            continue
        entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)))
        application_id = f"{team}.{bundle_id}"
        if entitlements.get("com.apple.application-identifier") != application_id or entitlements.get("com.apple.developer.team-identifier") != team:
            raise ValueError(f"{bundle_id} signed application/team identifiers do not match {application_id}")
        if GROUP not in entitlements.get("com.apple.security.application-groups", []):
            raise ValueError(f"{bundle_id} is missing App Group {GROUP}")
        profile_path = bundle / "Contents/embedded.provisionprofile"
        if not profile_path.is_file():
            raise ValueError(f"{bundle_id} needs an embedded provisioning profile authorizing its explicit App ID and {GROUP}; provision this capability in Xcode before packaging")
        profile = plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i", str(profile_path)))
        allowed = profile.get("Entitlements", {})
        if "OSX" not in profile.get("Platform", []):
            raise ValueError(f"{bundle_id} provisioning profile does not authorize macOS")
        profile_certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
        if leaf_fingerprint not in profile_certificates:
            raise ValueError(f"{bundle_id} provisioning profile does not authorize its actual signing certificate")
        if allowed.get("com.apple.application-identifier") != application_id or GROUP not in allowed.get("com.apple.security.application-groups", []):
            raise ValueError(f"{bundle_id} profile does not authorize explicit {application_id} and {GROUP}; a wildcard profile is insufficient")
        if team not in profile.get("TeamIdentifier", []) or allowed.get("com.apple.developer.team-identifier") != team:
            raise ValueError(f"{bundle_id} provisioning profile belongs to a different team")
        expiry = profile.get("ExpirationDate")
        if not expiry or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
            raise ValueError(f"{bundle_id} provisioning profile has expired")
    return team


def verify_previous_identity(app, team, kind=None):
    app = Path(app).resolve()
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    for relative, bundle_id, _ in COMPONENTS:
        bundle = app / relative
        details = signature(bundle)
        requirement(bundle)
        if field(details, "TeamIdentifier") != team:
            raise ValueError(f"Previous {bundle_id} belongs to a different signing team")
        authority = field(details, "Authority")
        if kind and not authority.startswith(kind + ":"):
            raise ValueError(f"Previous {bundle_id} is not signed with {kind}")
        run("/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple generic", str(bundle))
    # An old profile may have expired or lacked a capability. Only the candidate
    # needs current provisioning; rejecting the old profile would block its repair.


def compare(previous, candidate, require_code_change=False):
    previous, candidate = Path(previous).resolve(), Path(candidate).resolve()
    team = verify(candidate)
    verify_previous_identity(previous, team)
    changed = []
    for relative, bundle_id, _ in COMPONENTS:
        old, new = previous / relative, candidate / relative
        old_requirement, new_requirement = requirement(old), requirement(new)
        run("/usr/bin/codesign", "--verify", "--strict", "-R", "=" + old_requirement, str(new))
        run("/usr/bin/codesign", "--verify", "--strict", "-R", "=" + new_requirement, str(old))
        if field(signature(old), "CDHash") != field(signature(new), "CDHash"):
            changed.append(bundle_id)
    if require_code_change and not changed:
        raise ValueError("Code hashes did not change; this comparison does not prove identity continuity across a rebuild with changed code")
    print(f"All three component requirements are mutually compatible; changed code hashes: {', '.join(changed) or 'none'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    identity = commands.add_parser("identity")
    identity.add_argument("--identity")
    identity.add_argument("--team")
    profiles = commands.add_parser("profiles")
    profiles.add_argument("--team", required=True)
    profiles.add_argument("--certificate", required=True)
    check = commands.add_parser("verify")
    check.add_argument("app")
    check.add_argument("--team")
    check.add_argument("--certificate")
    check.add_argument("--kind", choices=("Apple Development", "Developer ID Application"))
    previous = commands.add_parser("identity-check")
    previous.add_argument("app")
    previous.add_argument("--team", required=True)
    previous.add_argument("--kind", choices=("Apple Development", "Developer ID Application"))
    continuity = commands.add_parser("compare")
    continuity.add_argument("previous")
    continuity.add_argument("candidate")
    continuity.add_argument("--require-code-change", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "identity":
            print("\t".join(resolve_identity(args.identity, args.team)))
        elif args.command == "profiles":
            verify_local_profiles(args.team, args.certificate)
        elif args.command == "identity-check":
            verify_previous_identity(args.app, args.team, args.kind)
            print("Previous signatures are stable; provisioning will be checked on the candidate")
        elif args.command == "verify":
            print(f"Verified stable signatures, explicit profiles and App Group for Team {verify(args.app, args.team, args.kind, args.certificate)}")
        else:
            compare(args.previous, args.candidate, args.require_code_change)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
