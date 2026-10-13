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

Blank tabs are named “Empty Tab” and show a transparent `about:blank` canvas. The toolbar plus button, sidebar New Tab button, and New Tab command (⌘T) open the glass search popup. Opening or dismissing it leaves the current page and tab list intact. Submitting a search or selecting a suggestion creates a tab for that destination; no empty tab is created first. It floats over the entire interface, centered horizontally in the full window including the sidebar, around its upper third. It settles into place from a larger, softly blurred entrance; suggestions animate below a stationary input. Visual typing feedback is smoothed without delaying the actual query or submission. Escape or clicking outside dismisses it. Launching, restoring or selecting an empty tab does not open it; ⌘L focuses the regular address field. The plus and refresh controls sit beside the sidebar toggle. Autocomplete uses local bookmarks, up to 1,000 recent history entries, and common site names. Private windows omit history suggestions. Typing never overwrites your query or navigates automatically: click a suggestion, or use ↑/↓ and Return to select one. The first autocomplete result is highlighted by default and Return opens it; arrow keys choose a different result. If there are no matches, Return opens/searches the typed input. No remote suggestion requests are sent.

Compact sidebar tabs display each page’s favicon and document title. The capsule address field is centered between matching navigation and action rails. Window dragging is confined to empty top-bar areas and the sidebar’s top strip, keeping text fields and website content free for selection. Its whole surface activates native text editing; clicks and ⌘L focus the field without automatically selecting the URL. Native typing, caret placement, text selection, clipboard commands, and input-method composition work normally. Its autocomplete offers site/history/bookmark matches plus a direct navigation or search action: ↑/↓ select a row, Return opens it, Tab moves focus normally, and Escape restores the typed query or exits editing. The page-actions menu uses a neutral icon and a full-size button hit target. Glass controls float above the page, and WebKit’s obscured-content insets keep fixed/sticky content clear of them. Google pages receive the system light/dark preference through WebKit; Google’s own saved appearance setting may override its device default. Tab and autocomplete selection use neutral scene-adaptive highlights; red is reserved for small accents and a faint search glow.

Websites sit inside a thin 6-point inset with continuous 12-point rounded corners. The sidebar and exposed edge share one continuous desktop-blended background that picks up the selected page’s color tint; white and near-white pages keep the neutral translucent material. Settings → General → Appearance includes a saved **Background grain** slider (0–100%, default 20%) and reset button. Grain changes apply immediately across windows; 0% removes the added texture. The native top bar matches WebKit’s derived page background color, including live changes; the sidebar keeps its translucent color tint on colored pages and returns to untinted desktop vibrancy on white or near-white pages. URL text is centered inside the capsule, and button hit targets cover their full surfaces. Website colors, HTML, and CSS are left exactly as authored.

## Spaces

The current space’s emoji and name sit directly below the sidebar’s top bar. Switch spaces using the emoji buttons at the bottom; the **+** button creates a space, and right-clicking the space name or its bottom emoji lets you rename it, change its emoji, or delete it. Each space has its own live tabs and remembers its selected tab. Drag a tab onto another space’s emoji, or use **Move to Space** from its context menu.

Pinned tabs sit above the divider. **↓ Clear** closes only the current space’s unpinned tabs below it; pinned tabs and other spaces stay open. Normal tabs can be recovered with **Reopen Closed Tab** (⇧⌘T). Deleting a space moves its tabs into another space rather than closing them.

Space names and emojis are saved for normal windows. Tabs and the selected space restore when session restoration is enabled. Restored background tabs keep their saved URLs and load when selected, so startup does not load every space at once. Private-window spaces and tabs stay within that window and are never saved. Previously saved Essentials links are preserved in Bookmarks.

## Interaction motion

Custom toolbar, sidebar, autocomplete, search, and panel controls use subtle hover lift, press compression, and a short spring return. The sidebar slides and collapses smoothly in either direction while preserving its scroll position. The native traffic lights slide and fade with it, hiding when the sidebar is collapsed and returning when it opens. The address bar gives spring feedback through its focus outline; its native editor stays still for caret placement, double-click word selection, and drag selection. Window dragging is limited to empty toolbar gaps and the sidebar's top strip. Reduce Motion disables these transforms and the sidebar animation.

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
| Type clipboard / stop typing | ⌘9 |
| Zoom in / out / reset | ⌘+ / ⌘− / ⌘0 |
| Save archive / print | ⌘S / ⌘P |
| Settings | ⌘, |

## Data and privacy

With **Spoof Mode enabled**, choose **Edit → Type Clipboard** or press **⌘9** to type clipboard text into the focused field, one character at a time. Delays vary between characters (usually 30–75 ms at the default speed), with slightly longer pauses at spaces and punctuation. Settings → Privacy → Clipboard typing offers a persistent **0.1×–10×** speed slider and **Reset to Default** (1×); every speed retains the randomized timing. Changes apply to the next typing run. Press ⌘9 again, type manually, click, or turn off Spoof Mode to stop. Typing also stops when the window or field loses focus; clipboard text is read only when you invoke the command. Unicode text is supported through native text input. Clipboard line breaks and tabs become spaces; other control characters are removed. It never presses Enter or Tab, pastes, or automatically submits forms.

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

Toggle **Spoof Mode** using the mask button beside Downloads, the page-actions menu, or Settings → Privacy. The mask fills and gains a neutral highlight while enabled. Off by default, it persists locally and applies across windows. A document-start script in every frame reports `hidden = false`, `visibilityState = "visible"`, and `hasFocus() = true`. It suppresses visibility/lifecycle, focus/blur (including controls), mouse/pointer boundary, pointer-cancellation, and touch-cancellation events. Listener and property-handler guards also cover detached elements and shadow roots. Clicks, text input, and native control focus remain functional; websites that depend on focus or hover event handlers may behave differently. The script does not generate input, change page styles, alter the user agent, or silence unrelated console logs.

An isolated-world frame registry uses WebKit frame identities to apply live toggles to existing cross-origin, sandboxed, nested, and dynamically loaded frames. Same-origin frame accessors also initialize accessible blank frames before a parent inspects them. Disabling restores activity accessors and handlers and removes suppression listeners. Passive add/remove callback-identity adapters remain so listeners registered while enabled can still be re-added and removed correctly while off. Frame registration remains active while off to support subsequent live toggles, and is removed when the tab closes.

This is best effort, not an undetectability guarantee. Enabling on an already loaded document cannot erase earlier observations or native references that a site already saved. Sites can still infer activity through timing, network requests, CSS hover/focus state, polling other APIs, or deliberate modification of the page-world patches. Reload with Spoof Mode enabled for document-start coverage.

## Performance

Restored tabs create their web views on demand. Regular library encoding and atomic writes use a serial background queue; quitting flushes the latest snapshot after pending writes. Window snapshots do not invalidate history/bookmark lists, WebKit property notifications are coalesced, and tab clearing saves one snapshot for the batch. Local suggestions retain their ranking while avoiding a full candidate sort, bitmap favicons are decoded off the UI thread at a maximum of 64 pixels, and grain updates stay within the backdrop view.

Spoof Mode uses one tracker per shared content controller. Reading an already configured iframe does not reinstall its patches; ordinary DOM updates are not scanned for frames. Document-start injection, native frame registration, and synchronous frame accessors retain iframe coverage. The review, measurements, and remaining limits are recorded in [the performance review](docs/PERFORMANCE_REVIEW.md).
