[P2] Avoid reinstalling spoof patches on every iframe read — Sources/Oasis/SpoofMode.swift:140

The reviewed change routes `contentWindow` and `contentDocument` through `install`, which calls `repair` even for an already configured document. A native WebKit fixture produced 68,000 descriptor writes for 1,000 reads of one loaded iframe. Fixed by making established-frame access a fast lookup; initialization and lifecycle repair still install the descriptors.

[P2] Remove document-wide subtree scans for ordinary page updates — Sources/Oasis/SpoofMode.swift:148

The new mutation observer queries every added element for descendant frames, including lists and other content with no frames. Adding 1,000 ordinary elements produced 1,000 queries. Fixed by removing this observer and retaining all-frame document-start injection, native registration, and synchronous frame accessors. Nested, sandboxed, cross-origin, and dynamic-frame checks still pass.

[P2] Share the frame tracker across related popup configurations — Sources/Oasis/SpoofFrameCoverage.swift:23

Every popup inherits its opener's content controller, but each tab previously appended a separate registration script and message handler to that shared controller. A growing popup group therefore ran and reported every tracker in every subsequent frame. Fixed with one controller-owned dispatcher that routes by WebKit's web-view identity and unregisters after its last client closes.

[P2] Apply each native frame update without revisiting descendants — Sources/Oasis/SpoofFrameCoverage.swift:39

The registry already iterates all registered frames, but each evaluation previously ran a script that recursively traversed that frame's descendants again. Nested frame trees therefore received repeated installations/restorations during a toggle. Fixed by using a frame-local script for registry updates and retaining the recursive fallback for accessible frames when a live toggle precedes registration.

[P2] Preserve listener identity when Spoof Mode is switched off — Sources/Oasis/SpoofMode.swift:172

A listener registered while enabled is stored as a wrapper. Restoring the native `addEventListener` permits the same original callback to be added alongside that wrapper while off, so a single event invokes it twice. Fixed by retaining passive add/remove identity adapters across toggles. Regression checks verify one invocation and successful removal after repeated toggles.

[P2] Release clipboard focus references after typing finishes — Sources/Oasis/ClipboardTyping.swift:38

The clipboard task stores document and element references in its isolated-world focus path, but `stop` previously left that path in the document. A removed input or iframe could remain retained after the run. Fixed with token-checked cleanup that also protects newer runs from cancellation of an older run; cancellation checks verify that the stored path is removed.

The review target was commit `b27cf9c` against its parent, including its tests and call sites. The line numbers above refer to that reviewed commit. All listed findings were addressed in this cleanup. Additional optimizations target pre-existing hot paths rather than regressions introduced by that commit: asynchronous library serialization/writes, separate observation for history/bookmarks/spaces, lazy restored web views, coalesced WebKit notifications, batched tab clearing, linear selection snapshots, bounded suggestion ranking, and small off-thread favicon decoding. Unused legacy favicon/ID fields, the unused bookmark predicate, obsolete generated icon files, and old Essentials previews were removed. Packaging rebuilds resources from current sources so stale assets cannot survive a previous build. The active Icon Composer asset and font/license resources remain in use. The observation split follows [Apple’s model dependency guidance](https://developer.apple.com/documentation/SwiftUI/Managing-model-data-in-your-app); bitmap downsampling uses [ImageIO’s thumbnail size limit](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize).

| Fixture | Before cleanup | After cleanup |
| --- | ---: | ---: |
| 1,000 reads of a configured iframe | 68,000 descriptor writes | 0 descriptor writes |
| 1,000 ordinary added elements | 1,000 subtree queries | 0 subtree queries |
| 40 restored tabs at activation | 40 eagerly created web views | 1 created web view |
| Two related tab configurations | Two frame trackers | One shared tracker |
| Tab saves observed by library lists | Invalidated all lists through shared data | No list invalidation |
| 1,024 × 512 bitmap favicon | Original-size image | 64 × 32 bitmap |

Validation uses native WebKit/SwiftUI-model tests, not a simulation of their APIs. The release suite covers iframe toggles, back/forward navigation, listener restoration, popup tracker lifetime, restoration/selection, save ordering and background execution, library observation boundaries, suggestions, favicon dimensions, clipboard input/cancellation, private data, and window controls. All 45 release tests pass, including a back/forward check with a separate-origin child frame. Cached frame trees are explicitly reconciled during history navigation because suppressed page-world lifecycle events can also prevent an isolated-world pageshow listener from seeing the transition. The same 45 tests also pass in debug. The build scripts pass shell syntax checks, the app manifest passes validation, and the task response links the verified release DMG.

These measurements establish reductions in app-generated work, not a universal scrolling FPS or memory percentage. No user-session Instruments trace was available. Active websites can still consume substantial resources, especially when Spoof Mode reports them as visible; its detection limitations remain documented in the README. Saved library corruption remains protected from overwrite, and private session snapshots remain excluded from persistence. Explicit exit flushing is synchronous so the final saved state is complete before termination.
