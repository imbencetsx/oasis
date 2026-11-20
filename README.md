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

## Spoof Mode

Toggle **Spoof Mode** from the theater-masks button in the toolbar. Right-click
it (or choose **Spoof Mode Settings…** in the page menu) to open
**Settings → Spoof Mode**, where each feature can be switched on or off. Changes
apply immediately to open tabs; reload a page for coverage from the start of
the document. Every feature is on by default:

| Feature | What websites see |
| --- | --- |
| Focus & document visibility | The page is always visible and focused. Window blur/focus, visibility, page-lifecycle events and the pointer leaving the page are hidden; focus moving between inputs still works. Chromium's native focus emulation is used as well. |
| Fullscreen lock & notification suppression | The page always reports fullscreen. It renders at your display's full-screen resolution, scaled to fit the window (letterboxed), so screen, window and viewport sizes match a full-screen browser and never change. Fullscreen and resize events are hidden; real fullscreen requests still work. |
| Selective keyboard listener filtering | Characters typed into text boxes reach the page; shortcuts and other keys are hidden from key listeners. Typing itself is unaffected. |
| Clipboard event protection | Copy, cut and paste events are hidden from page scripts. Copying and pasting still work. |
| Force enable right-click context menu | Pages cannot block the context menu. |
| Text selection protection | `user-select: none` is relaxed on the clicked text, mouse-down cancellation is ignored, and selection APIs report an empty selection while the real selection still works. |
| Screenshare surface spoofing | Tab sharing is offered to the page. The share sheet lets you report it as a **Full screen** or a **Single tab**; track settings, capabilities, constraints and labels follow that choice. |
| Screenshare cursor containment | When the pointer leaves a shared tab, the shared stream shows it parked ~1 cm inside the edge it left through, and the page's pointer position moves there too. Returning continues from that point. |
| OS & platform spoofing | Windows 11 x64, Linux x64 or macOS x64. |
| Browser identity spoofing | Google Chrome, Microsoft Edge, Mozilla Firefox or Apple Safari: User-Agent, navigator fields, Client Hints and `window.chrome` match the choice. |

Spoof Mode also covers embedded frames, including cross-site frames that run in
a separate renderer process. It is best effort: sites can still observe other
signals, and it cannot guarantee that switching tabs or windows is undetectable.

### Screen and tab sharing

With **Spoof Mode** and screenshare spoofing enabled, an HTTPS page can ask to
share your screen. The share sheet offers:

- **This tab** – only this tab's webview is captured: no address bar, sidebar,
  other tabs, desktop, or audio. The feed stays tied to the originating tab when
  you switch tabs, keeps updating in the background, and needs no Screen
  Recording permission. Entering or leaving fullscreen never shows a zoom step
  in the feed.
- **Entire screen** – the whole display (one entry per display), including the
  pointer, through ScreenCaptureKit. macOS asks for Screen Recording permission
  the first time; allow [oasis] in System Settings › Privacy & Security ›
  Screen & System Audio Recording, then reopen it and share again.

**Report to website as** chooses whether the website sees a full screen or a
single tab, whatever is actually shared. Feeds are up to 1440 (tab) or 1600
(screen) pixels wide. Use **Sharing → Stop Sharing** in the macOS menu bar to
stop; navigating or closing the sharing tab, or disabling Spoof Mode, also stops
it. Changing other Spoof Mode settings keeps a share running. The custom sharing
API and metadata patches are removed when Spoof Mode is disabled;
website/server acceptance depends on their other checks.

## Your data

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

Tests cover navigation and suggestions, library persistence, private storage, spaces, lazy restoration, iframe spoofing, clipboard typing, favicon sizing, and native window controls. WebKit is retained as a compatibility test backend when the CEF runtime is not bootstrapped. In a bundled debug app, Developer → Run Chromium Checks exercises the actual Chromium runtime: the fullscreen lock, browser identities, keyboard and selection filtering, same- and cross-site iframe scripts, API restoration, page capture, and live repainting while the source tab is in the background. To run them unattended, launch the debug app binary with `OASIS_CHROMIUM_CHECKS=<page URL>` (and optionally `OASIS_CHROMIUM_CHECKS_OUTPUT=<report.json>`); it opens the page, writes the report and quits. Archives are exported in Chromium’s MHTML format.
