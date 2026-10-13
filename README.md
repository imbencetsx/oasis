# [oasis]

> A calmer place for the web.

**[oasis] is a native macOS browser built with SwiftUI and WebKit.** Organize tabs into spaces, browse with a translucent sidebar, and keep your history and bookmarks on your Mac. Liquid Glass controls, page-colored backgrounds, and adjustable grain give the window a quiet, cohesive feel.

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

## Development and checks

Open `Package.swift` in Xcode, or build and test from the terminal:

```bash
swift test
swift test -c release
```

Tests cover navigation and suggestions, library persistence, private storage, spaces, lazy restoration, iframe spoofing, clipboard typing, favicon sizing, and native window controls.
