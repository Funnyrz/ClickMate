# ClickMate

[中文文档](README.zh-CN.md)

ClickMate is a native macOS Finder context-menu enhancer built with SwiftUI, AppKit, and a Finder Sync extension. It adds a configurable `ClickMate` submenu to Finder so common file and folder actions are available directly from right-click menus.

![ClickMate Finder menu](img/clickmate-menu-en.png)

![ClickMate settings window - menus](img/clickmate-settings-1-en.png)

![ClickMate settings window - permissions](img/clickmate-settings-2-en.png)

## Features

- Finder integration for selected files, selected folders, and monitored folder backgrounds.
- New file templates for text, Markdown, JSON, CSV, HTML, CSS, JavaScript, Swift, Python, and custom extensions.
- Copy helpers for POSIX paths, file URLs, shell-escaped paths, filenames, basenames, extensions, and parent folders.
- Open helpers for Terminal, iTerm2, VS Code, Cursor, BBEdit, Sublime Text, and pinned custom apps.
- Hash helpers for SHA-256, SHA-1, and MD5.
- File utilities for revealing parent folders, timestamped duplicates, aliases, moving items to a new folder, and compression.
- Advanced helpers for metadata, image dimensions, and toggling hidden files.
- Settings UI for menu layout, templates, app detection, pinned apps, and monitored folders.

## Requirements

- macOS 14.0 or later.
- Xcode with macOS development tools.
- A local Apple Development team is optional for unsigned development builds, but required for a fully signed Finder extension distribution.

## Build

Open the project in Xcode:

```sh
open ClickMate.xcodeproj
```

Or build from the command line:

```sh
xcodebuild build -project ClickMate.xcodeproj -scheme ClickMate -destination 'platform=macOS'
```

For local unsigned verification, disable code signing explicitly:

```sh
xcodebuild build -project ClickMate.xcodeproj -scheme ClickMate -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ClickMate.xcodeproj -scheme ClickMate -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The Debug configuration is intended for local development. Release builds keep the entitlement files used for real distribution signing.

## Run Locally

1. Open `ClickMate.xcodeproj` in Xcode.
2. Select the `ClickMate` scheme.
3. For a fully functional signed extension build, set a development team for the app and Finder extension targets and enable the App Group entitlement.
4. Run the app.
5. Open System Settings and enable the ClickMate Finder extension under Extensions.
6. Relaunch Finder if the menu does not appear immediately:

```sh
killall Finder
```

Right-click in Desktop, Documents, Downloads, or folders added in ClickMate's Permissions tab.

## Online Updates

ClickMate automatically checks the latest published GitHub Release at most once every 24 hours and compares its tag with the installed app's `CFBundleShortVersionString`. A leading `v` in the release tag is ignored for comparison. Drafts and prereleases are not offered as normal updates. A manual check bypasses the 24-hour interval.

When a newer version is available, ClickMate notifies you once for that version and directs you to a trusted GitHub release page so you can download and replace the app manually. It does not silently download or install updates. Automatic-check failures stay silent; manual checks report failure without preventing the installed app from continuing to work.

Release downloads must be built with a stable Developer ID Application identity and notarized. The main app, background Helper, and Finder Extension keep fixed bundle identifiers and the same Team ID so macOS permissions remain associated with the installed product across normal upgrades.

## Package a Signed Release DMG

Set a Developer ID Application identity and a `notarytool` keychain profile, then run:

```sh
export CLICKMATE_DEVELOPMENT_TEAM='YOUR_TEAM_ID'
export CLICKMATE_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)'
export CLICKMATE_NOTARY_PROFILE='clickmate-notary'
Scripts/package_signed_dmg.sh
```

The script archives and exports the app through Xcode automatic Developer ID signing so the main app and Finder Extension receive authorized provisioning profiles for `group.com.zxacn`. It rejects missing profiles, application/team identifier mismatches, missing App Group authorization, unstable bundle identifiers, non-Developer-ID signatures, or components without hardened runtime. It verifies notarization and Gatekeeper assessment before producing a release artifact.

## Package an Unsigned DMG

The repository includes a helper script for creating a local unsigned DMG:

```sh
Scripts/package_unsigned_dmg.sh
```

The generated DMG can be copied to `/Applications` for local functional diagnostics, including the basic Finder Extension menu in safe folders. Its ad-hoc identity can change after rebuilds, so macOS may require Accessibility, Screen Recording, and Full Disk Access again. The packaging script intentionally removes the App Group entitlement: custom Finder settings synchronization, runtime status sharing, and automatic permission verification are unavailable. Do not use it for release or permission-identity stability acceptance.

## Package a Local Apple Development DMG

Use one stable development team for the main app, Helper, and Finder Extension:

```sh
export CLICKMATE_DEVELOPMENT_TEAM='YOUR_TEAM_ID'
# Optional: set an exact certificate SHA when multiple identities share a name.
export CLICKMATE_DEVELOPMENT_IDENTITY='CERTIFICATE_SHA'
Scripts/package_development_dmg.sh
```

The script uses Xcode automatic signing instead of manually re-signing an unsigned app. It rejects missing provisioning profiles, application/team identifier entitlements, App Group authorization, hardened runtime, mismatched Team IDs or Bundle IDs, invalid nested signatures, and non-Universal binaries. This package is suitable for local Finder Extension and permission acceptance, but not for public distribution.
Use the Team ID reported by `codesign`/the certificate subject OU; the text in a certificate display name can be misleading.

## Publish a GitHub Release Locally

Install and authenticate GitHub CLI, and make sure `curl`, `jq`, and the Xcode command-line tools are available. Update `CFBundleShortVersionString` in both `ClickMate/Info.plist` and `ClickMateFinderExtension/Info.plist`, then commit the release changes.

Create and push the release tag yourself, configure `CLICKMATE_DEVELOPMENT_TEAM`, `CLICKMATE_SIGNING_IDENTITY`, and `CLICKMATE_NOTARY_PROFILE`, then run the release script:

```sh
git tag -a v1.4 -m "Release v1.4"
git push origin v1.4
Scripts/release_github.sh v1.4
```

The script also accepts `1.4` and normalizes it to `v1.4`. It requires a clean working tree; verifies that both bundle versions match; confirms that the local and `origin` tags both point at `HEAD`; rejects an existing release or a version that is not strictly newer than the latest published GitHub release; runs the test suite; builds and notarizes the DMG with `Scripts/package_signed_dmg.sh`; mounts it read-only to verify the app, Finder extension, versions, and `arm64` + `x86_64` executables; then creates the GitHub release and uploads the signed artifact.

`Scripts/release_github.sh` never creates, moves, or pushes tags. It fails instead of falling back to an unsigned artifact when signing or notarization configuration is unavailable.

## Contributing

Contributions are welcome. Please keep changes focused, follow the existing Swift and SwiftUI style, and verify relevant behavior with `xcodebuild test` when changing app logic.

## License

ClickMate is released under the [MIT License](LICENSE).
