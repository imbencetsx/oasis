# [oasis]

> A calmer place for the web.

A clean native macOS browser built with SwiftUI and WebKit. Translucent windows, Liquid Glass controls, sidebar tabs, local history, bookmarks, and private browsing keep the experience familiar and focused. Requires **macOS 26+ and Xcode 26+** with the Swift 6.2 toolchain or later.

## Run

```bash
./scripts/run.sh
```

This builds and opens `build/[oasis].app`. You can also open `Package.swift` in Xcode to work on the source. For an optimized app:

```bash
./scripts/build-app.sh release
open 'build/[oasis].app'
```

The local build is signed ad hoc for use on your own Mac. Distribution would require a developer signing identity and notarization. No external packages are required.

## App and DMG

```bash
./scripts/build-dmg.sh
```

Creates the optimized `build/[oasis].app` and `dist/[oasis].dmg`. Open the DMG and drag **[oasis]** to **Applications**. Its Finder window uses a minimal dark background with a Geist Mono wordmark and an Applications shortcut. The app currently uses the generic macOS application icon; no custom icon is bundled.

Packaging requires Python 3 and downloads its pinned tooling into the ignored `build/dmg-tools` environment on first use. Build outputs and local credentials are excluded from Git. The app is signed ad hoc; public distribution still requires Developer ID signing and notarization.

[Geist Mono](https://github.com/vercel/geist-font) is bundled under the SIL Open Font License; see `Resources/Fonts/OFL.txt`. A ready-to-copy GitHub repository description lives in [docs/GITHUB_DESCRIPTION.md](docs/GITHUB_DESCRIPTION.md).

## Included

- Sidebar tabs with selection, close, pin, duplicate, drag reordering, and reopening recently closed tabs.
- Normal and private windows start with no tabs. Closing the last tab returns to an empty window. Session restoration is available as an opt-in setting.
- Address/search field; DuckDuckGo, Google, Bing, and Brave search; native navigation and swipe gestures.
- Searchable history, bookmarks/favorites, and reading list in the Library panel. Open it from History/Bookmarks menus or the floating page-actions menu.
- HTML bookmark import/export, history clearing, configurable history retention, website-data removal.
- Downloads with a save-location prompt, progress, cancellation, and reveal in Finder. Download records last for the app session; saved files remain on disk.
- File uploads, JavaScript dialogs, HTTP authentication, and per-request camera/microphone permission prompts.
- Find, zoom, a text-based Reader, printing, PDF export, and web archives.
- System/light/dark appearance, a red accent, and transparent blank new tabs with a floating Liquid Glass search popup. Websites render using their original styling.
- Default browser registration from Settings when running the app bundle.

## Design

Blank tabs are named “Empty Tab” and show a transparent `about:blank` canvas. Only the toolbar plus button or the New Tab command (⌘T) opens the glass search popup. Opening or dismissing it leaves the current page and tab list intact. Submitting a search or selecting a suggestion creates a tab for that destination; no empty tab is created first. It floats over the entire interface, centered horizontally in the full window including the sidebar, around its upper third. It settles into place from a larger, softly blurred entrance; suggestions animate below a stationary input. Visual typing feedback is smoothed without delaying the actual query or submission. Escape or clicking outside dismisses it. Launching, restoring or selecting an empty tab does not open it; ⌘L focuses the regular address field. The plus and refresh controls sit beside the sidebar toggle. Autocomplete uses local bookmarks, up to 1,000 recent history entries, and common site names. Private windows omit history suggestions. Typing never overwrites your query or navigates automatically: click a suggestion, or use ↑/↓ and Return to select one. The first autocomplete result is highlighted by default and Return opens it; arrow keys choose a different result. If there are no matches, Return opens/searches the typed input. No remote suggestion requests are sent.

Compact sidebar tabs display each page’s favicon and document title. The capsule address field is centered between matching navigation and action rails. Window dragging is confined to empty top-bar areas and the sidebar’s top strip, keeping text fields and website content free for selection. Its whole surface activates native text editing; clicks and ⌘L focus the field without automatically selecting the URL. Native typing, caret placement, text selection, clipboard commands, and input-method composition work normally. Its autocomplete offers site/history/bookmark matches plus a direct navigation or search action: ↑/↓ select a row, Return opens it, Tab moves focus normally, and Escape restores the typed query or exits editing. The page-actions menu uses a neutral icon and a full-size button hit target. Glass controls float above the page, and WebKit’s obscured-content insets keep fixed/sticky content clear of them. Google pages receive the system light/dark preference through WebKit; Google’s own saved appearance setting may override its device default. Tab and autocomplete selection use neutral scene-adaptive highlights; red is reserved for small accents and a faint search glow.

The native top bar matches WebKit’s derived page background color, including live changes; the sidebar keeps its translucent color tint on colored pages and returns to untinted desktop vibrancy on white or near-white pages. URL text is centered inside the capsule, and button hit targets cover their full surfaces. Website colors, HTML, and CSS are left exactly as authored.

## Interaction motion

Custom toolbar, sidebar, autocomplete, search, and panel controls use subtle hover lift, press compression, and a short spring return. The sidebar slides and collapses smoothly in either direction while preserving its scroll position. The address bar gives spring feedback through its focus outline; its native editor stays still for caret placement, double-click word selection, and drag selection. Window dragging is limited to empty toolbar gaps and the sidebar's top strip. Reduce Motion disables these transforms and the sidebar animation.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| New tab / window / private window | ⌘T / ⌘N / ⇧⌘N |
| Address field | ⌘L |
| Close / reopen tab | ⌘W / ⇧⌘T |
| Back / forward | ⌘[ / ⌘] |
| Previous / next tab | ⇧⌘[ / ⇧⌘] |
| History / bookmark / reading list | ⌘Y / ⌘D / ⇧⌘D |
| Find / reload / Reader | ⌘F / ⌘R / ⇧⌘R |
| Zoom in / out / reset | ⌘+ / ⌘− / ⌘0 |
| Save archive / print | ⌘S / ⌘P |
| Settings | ⌘, |

## Data and privacy

Normal history, bookmarks, reading-list entries, and restored tabs are stored in `~/Library/Application Support/Oasis/Library.json`. Website cookies/cache use WebKit's app-specific persistent store. Each private window gets a separate nonpersistent store shared by its tabs; it never writes history or tab snapshots. Bookmarks and files saved in private windows remain on your Mac. Private browsing does not conceal activity from websites or network providers. Oasis does not run an analytics or synchronization service.

## Checks

```bash
swift test
```

The tests cover address resolution and search escaping, library round-tripping, preservation of damaged data, private-store isolation, tab selection/restoration, and preservation of original webpage colors without injected styles. For a local manual browser fixture:

```bash
python3 scripts/smoke-server.py
```

Open `http://127.0.0.1:8793` in Oasis to check navigation, popups, dialogs, Reader, file selection, and downloads.

## Current limits

Oasis implements the browser essentials listed above. Safari extensions/WebExtensions management, password/payment autofill, passkey UI integration, cloud sync, an ad-blocking rule manager, offline reading-list snapshots, downloadable-history restoration, and resumable downloads are not implemented. Reader extracts article text and does not reproduce Safari's article parsing. Website-specific behavior depends on the installed system WebKit and may need further testing.

The improved brief is saved in [docs/APP_PROMPT.md](docs/APP_PROMPT.md).

## Spoof Mode

Toggle **Spoof Mode** using the mask button beside Downloads, the page-actions menu, or Settings → Privacy. The mask fills and gains a neutral highlight while enabled. Off by default, it persists locally and applies across windows. When enabled, a document-start script in each frame reports `hidden = false`, `visibilityState = "visible"`, and `hasFocus() = true`, and suppresses visibility/lifecycle, window-focus, and mouse/pointer boundary events, including synthetic versions of those events. Real input and form-control focus are preserved; the app does not generate fake clicks or typing, change page styles, or alter the user agent. The current preference is reapplied when navigation commits and finishes, and the script repairs its accessors on lifecycle transitions without stacking listeners. Window-deactivation blur is suppressed while normal in-page focus changes remain available. Disabling restores the original descriptors and removes the installed event listeners in accessible frames, including when revisiting cached pages. Oasis does not silence unrelated page console logs.

Live changes affect the current document and reachable same-origin frames. Reload open pages after toggling for early event coverage and already-loaded cross-origin frames. This is best effort: sites can infer activity through timing, network requests, CSS hover state, and other APIs; it is not anonymity or an undetectability guarantee. Hover-driven site features may change.
