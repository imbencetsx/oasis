# [oasis]

> A calmer place for the web.

**[oasis] is a native macOS browser built with SwiftUI and WebKit.** Organize tabs into emoji spaces, browse with a translucent sidebar, and keep your history and bookmarks on your Mac. Liquid Glass controls, page-colored backgrounds, and adjustable grain give the window a quiet, cohesive feel.

## Requirements

- **macOS 26 or later** to run the app.
- **Xcode 26 or later**, with Swift 6.2 or later, to build it.
- **Python 3** for DMG packaging.

The Swift package has no external package dependencies. Run the commands below from the repository root.

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

The packaging script creates `dist/[oasis].dmg`. Open it and drag **[oasis]** to **Applications**. On its first run, the script installs pinned packaging tools into `build/dmg-tools`.

Local builds are signed ad hoc and are not notarized. Public distribution requires Developer ID signing and notarization.

## What’s inside

- **Spaces:** separate tab collections with a name, emoji, and remembered selection.
- **Sidebar tabs:** pin, duplicate, reorder, move between spaces, and reopen recently closed tabs.
- **Local search suggestions:** bookmarks, recent history, and common websites, with DuckDuckGo, Google, Bing, or Brave for searches you submit.
- **Library:** searchable history, favorites, bookmarks, and a reading list, plus HTML bookmark import and export.
- **Private windows:** separate temporary website storage, with no saved browsing history or restored private tabs.
- **Page tools:** find, zoom, text-based Reader, printing, PDF export, and web archives.
- **Downloads:** choose a destination, follow progress, cancel, and reveal saved files in Finder.
- **macOS integration:** navigation gestures, file uploads, website dialogs, authentication, camera/microphone prompts, and default-browser registration.
- **Appearance:** system, light, or dark interface; translucent page-tinted backgrounds; rounded website corners; and a background-grain slider with a reset button.

## Browsing and spaces

Windows start with no tabs unless session restoration is enabled. Press **⌘T** or choose **New Tab** to open the floating search field. Use **↑ / ↓** to choose a suggestion and **Return** to open it; **Escape** dismisses the field. Suggestions stay local until you open a destination or submit a search.

The current space’s name appears near the top of the sidebar. Select another space using the emoji buttons at the bottom, or use **+** to create one. Right-click a space to rename it, change its emoji, or delete it. Drag a tab onto another space’s emoji to move it there.

Pinned tabs sit above the divider. **↓ Clear** closes only the current space’s unpinned tabs; pinned tabs and other spaces stay open. Deleting a space moves its tabs into another space. Normal closed tabs can be reopened with **⇧⌘T**.

Enable **Settings → General → Restore windows and tabs on launch** to keep your session between launches. Restored background tabs load when selected, reducing startup work and memory use. Tabs you have already opened keep their live web views when you switch spaces.

Collapsing the sidebar also hides the native traffic lights. Motion follows the system’s Reduce Motion setting. Website styling stays as authored.

## Spoof Mode and clipboard typing

Toggle **Spoof Mode** using the mask button or **Settings → Privacy**. Off by default, it reports pages as visible and focused and suppresses visibility, focus/blur, and mouse/pointer boundary signals, including in embedded frames. Live toggles cover cross-origin, sandboxed, nested, and dynamically loaded frames.

This is best-effort activity suppression, not anonymity or an undetectability guarantee. Timing, network behavior, CSS state, and other APIs can still reveal activity. Reload with Spoof Mode enabled for coverage from document start. Websites that depend on focus or hover events may behave differently.

With Spoof Mode enabled, press **⌘9** to type the clipboard into the focused field with randomized pauses. **Settings → Privacy → Clipboard typing** controls the speed from **0.1× to 10×**, with **Reset to Default** returning it to **1×**.

Press **⌘9** again, type manually, click, or turn off Spoof Mode to cancel. Clipboard text is read only when you invoke the command. Line breaks and tabs become spaces; typing does not press Enter or Tab.

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

History, bookmarks, reading-list entries, spaces, and normal-window snapshots are stored locally in:

```text
~/Library/Application Support/Oasis/Library.json
```

Normal website cookies and caches use WebKit’s persistent store. Each private window gets its own nonpersistent store, shared by that window’s tabs. Private history, spaces, and tab snapshots are not saved; bookmarks and downloaded files you explicitly save remain on your Mac.

Settings includes history-retention controls and website-data removal. [oasis] has no account, analytics, or cloud-sync service. Private browsing does not hide your activity from websites or network providers.

## Development and checks

Open `Package.swift` in Xcode, or build and test from the terminal:

```bash
swift test
swift test -c release
```

Tests cover navigation and suggestions, library persistence, private storage, spaces, lazy restoration, iframe spoofing, clipboard typing, favicon sizing, and native window controls.

For a local manual browsing fixture:

```bash
python3 scripts/smoke-server.py
```

Open **http://127.0.0.1:8793** in [oasis] to exercise navigation, popups, dialogs, Reader, file selection, and downloads.

Generated apps, DMGs, packaging tools, and build caches are ignored by Git. The custom app icon is compiled from `Resources/AppIcon.icon`. [Geist Mono](Resources/Fonts/OFL.txt) is bundled under the SIL Open Font License.

## Current scope

[oasis] is a focused browser project. Extensions, password/payment autofill, dedicated passkey UI, cloud sync, an ad-blocking rule manager, offline reading-list snapshots, persistent download history, and resumable downloads are not implemented. Reader extracts article text rather than reproducing Safari’s article parsing. Website compatibility depends on the installed system WebKit.

For more project detail, see the [performance review](docs/PERFORMANCE_REVIEW.md), [design brief](docs/APP_PROMPT.md), and [repository description](docs/GITHUB_DESCRIPTION.md).
