# [oasis]

> A calmer place for the web.

**[oasis] is a native macOS browser built with SwiftUI and Chromium (CEF).** Organize tabs into spaces, browse with a translucent sidebar, and keep your history and bookmarks on your Mac. Liquid Glass controls, page-colored backgrounds, and adjustable grain give the window a quiet, cohesive feel.

## Requirements

- **macOS 26 or later** to run the app.
- **Xcode 26 or later**, with Swift 6.2 or later, to build it.
- **Python 3** for DMG packaging.

The SwiftUI shell uses a pinned, vendored CefSwift bridge in `Vendor/CefSwift`. The build script downloads the matching CEF runtime into `.cef/`, verifies its checksum, and bundles Chromium and its sandboxed helpers. Run the commands below from the repository root.

## Get started

Build and open a development app:

```bash
./scripts/run.sh
```

For an optimized build:

```bash
./scripts/build-app.sh release
open 'build/[oasis].app'
```

To create an installer:

```bash
./scripts/build-dmg.sh
```

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New tab search | ⌘T |
| New window | ⌘N |
| New private window | ⇧⌘N |
| Focus address field | ⌘L |
| Close / reopen tab | ⌘W / ⇧⌘T |
| Back / forward | ⌘[ / ⌘] |
| Previous / next tab in the current space | ⇧⌘[ / ⇧⌘] |
| Find / reload page | ⌘F / ⌘R |
| Toggle Reader | ⇧⌘R |
| Show history | ⌘Y |
| Add bookmark / add to reading list | ⌘D / ⇧⌘D |
| Type clipboard / stop typing | ⌘9 |
| Zoom in / out / reset | ⌘+ / ⌘− / ⌘0 |
| Save web archive / print | ⌘S / ⌘P |
| Settings | ⌘, |

## Your data

With **Spoof Mode** enabled, an HTTPS page can request sharing of its own tab.
Approve **Share Tab** to start. Only that tab's webview is captured: no address
bar, sidebar, other tabs, desktop, or audio. The recorded cursor stays at its last page position when you leave the page. The feed stays tied to the
originating tab when you open or switch to another tab, and it keeps updating
in the background. Native Screen Recording permission is not required.

The feed uses a fixed canvas at up to 10 frames per second and 1440 pixels wide.
Temporary snapshot failures retain the last frame and retry automatically. Use
**Sharing → Stop Sharing** in the macOS menu bar to stop; navigating or closing
the shared tab, or disabling Spoof Mode, also stops it. The custom sharing API
and metadata patches are removed when Spoof Mode is disabled. Shared tracks
retain the spoofed monitor identity through settings, capabilities, constraints,
labels, and clones; website/server acceptance depends on their other checks.

History, bookmarks, reading-list entries, spaces, and normal-window snapshots are stored locally in:

```text
~/Library/Application Support/Oasis/Library.json
```

Normal website cookies and caches use Chromium’s persistent profile at `~/Library/Application Support/com.oasis.browser/Chromium`. Each private window gets its own in-memory CEF profile, shared by that window’s tabs. Existing WebKit website storage remains separate; bookmarks, history, and spaces retain their existing library. Private history, spaces, and tab snapshots are not saved; bookmarks and downloaded files you explicitly save remain on your Mac.

## Development and checks

Open `Package.swift` in Xcode, or build and test from the terminal:

```bash
swift test
swift test -c release
```

Tests cover navigation and suggestions, library persistence, private storage, spaces, lazy restoration, iframe spoofing, clipboard typing, favicon sizing, and native window controls. WebKit is retained as a compatibility test backend when the CEF runtime is not bootstrapped. In a bundled debug app, Developer → Run Chromium Checks exercises the actual Chromium runtime, fullscreen signals, iframe scripts, API restoration, page capture, and live repainting while the source tab is in the background. Archives are exported in Chromium’s MHTML format.
