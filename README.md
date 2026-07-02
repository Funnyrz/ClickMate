# ClickMate

ClickMate is a native macOS Finder enhancer built with SwiftUI, AppKit, and a Finder Sync extension.

## Features

- Finder `ClickMate` submenu for selected files, selected folders, and monitored folder backgrounds.
- New file templates for text, Markdown, JSON, CSV, HTML, CSS, JavaScript, Swift, Python, and custom extensions.
- Copy helpers for POSIX paths, file URLs, shell-escaped paths, filenames, basenames, extensions, and parent folders.
- Open helpers for Terminal, iTerm2, VS Code, Cursor, BBEdit, Sublime Text, and pinned custom apps.
- Hash helpers for SHA-256, SHA-1, and MD5.
- File utilities for reveal parent, timestamp duplicate, alias creation, move to new folder, and basic app handoff.
- Settings UI for menus, templates, app detection, and monitored folders.

## Build

The Debug configuration is set to local ad-hoc signing so the project can build without an Apple Developer team. Release keeps the entitlement files for real distribution signing.

```sh
xcodebuild build -project ClickMate.xcodeproj -scheme ClickMate -destination 'platform=macOS'
```

For local unsigned verification:

```sh
xcodebuild build -project ClickMate.xcodeproj -scheme ClickMate -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ClickMate.xcodeproj -scheme ClickMate -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Manual Finder QA

1. Open `ClickMate.xcodeproj` in Xcode.
2. For a fully functional signed extension build, set a development team for the app and Finder extension targets and enable the App Group entitlement.
3. Run the `ClickMate` scheme.
4. Open System Settings and enable the ClickMate Finder extension under Extensions.
5. Relaunch Finder if needed:

```sh
killall Finder
```

Right-click in Desktop, Documents, Downloads, or folders added in ClickMate's Permissions tab.
