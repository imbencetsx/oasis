import WebKit

/// Best-effort suppression of activity signals exposed to page JavaScript.
/// This does not alter HTML/CSS, synthesize input, or conceal network identity.
enum SpoofMode {
  // Keep ownership compatible with earlier versions when replacing installed scripts.
  static let marker = "/* Oasis activity privacy"
  static let source = """
    /* Oasis activity privacy v2 */
    (() => {
      const key = '__oasisActivityPrivacy_v2';
      function install(w) {
        try {
          const d = w.document;
          const existing = w[key];
          if (existing?.document === d) {
            existing.repair();
          } else {
            // Upgrade a live document from the previous implementation cleanly.
            w.__oasisRestoreActivityPrivacy_v1?.();
            const patches = [];
            const nativeHasFocus = w.Document.prototype.hasFocus;
            function patch(object, name, descriptor) {
              const original = Object.getOwnPropertyDescriptor(object, name);
              patches.push({ object, name, original, descriptor: {
                ...descriptor, configurable: true, enumerable: original?.enumerable ?? false
              }});
            }
            const proto = w.Document.prototype;
            for (const object of [proto, d]) {
              for (const name of ['hidden', 'webkitHidden'])
                patch(object, name, { get: () => false });
              for (const name of ['visibilityState', 'webkitVisibilityState'])
                patch(object, name, { get: () => 'visible' });
              patch(object, 'hasFocus', { value: function hasFocus() { return true; }, writable: true });
            }
            function repair() {
              for (const p of patches) {
                try { Object.defineProperty(p.object, p.name, p.descriptor); } catch (_) {}
              }
            }
            const visibility = new Set(['visibilitychange', 'webkitvisibilitychange',
                                        'pagehide', 'pageshow', 'freeze', 'resume']);
            const boundary = new Set(['mouseenter', 'mouseleave', 'mouseover', 'mouseout',
                                     'pointerenter', 'pointerleave', 'pointerover', 'pointerout']);
            const focus = new Set(['focus', 'blur', 'focusin', 'focusout']);
            function suppress(event) {
              // Repair after lifecycle transitions, including back/forward-cache restoration.
              if (visibility.has(event.type)) repair();
              let windowBlur = false;
              if (event.type === 'blur' || event.type === 'focusout') {
                try { windowBlur = !nativeHasFocus.call(d); } catch (_) {}
              }
              const rootFocus = focus.has(event.type) &&
                (event.target === w || event.target === d ||
                 event.target === d.documentElement || event.target === d.body || windowBlur);
              // Cover synthetic versions too; genuine clicks, typing and in-page focus remain native.
              if (visibility.has(event.type) || boundary.has(event.type) || rootFocus) {
                event.stopImmediatePropagation();
                event.stopPropagation();
              }
            }
            function frameLoaded(event) {
              if (event.target?.tagName === 'IFRAME' || event.target?.tagName === 'FRAME') {
                try { install(event.target.contentWindow); } catch (_) {}
              }
            }
            const types = [...visibility, ...boundary, ...focus];
            for (const type of types) w.addEventListener(type, suppress, true);
            d.addEventListener('load', frameLoaded, true);
            const state = { document: d, repair, restore() {
              for (const type of types) w.removeEventListener(type, suppress, true);
              d.removeEventListener('load', frameLoaded, true);
              for (const p of [...patches].reverse()) {
                try {
                  if (p.original) Object.defineProperty(p.object, p.name, p.original);
                  else delete p.object[p.name];
                } catch (_) {}
              }
              delete w[key];
            }};
            Object.defineProperty(w, key, { configurable: true, value: state });
            repair();
          }
          // An inaccessible frame must not prevent subsequent frames from being processed.
          for (let i = 0; i < w.frames.length; i++) {
            try { install(w.frames[i]); } catch (_) {}
          }
        } catch (_) {}
      }
      install(window);
    })();
    """

  static let restoreSource = """
    (() => {
      function restore(w) {
        try {
          w.__oasisActivityPrivacy_v2?.restore();
          w.__oasisRestoreActivityPrivacy_v1?.();
          for (let i = 0; i < w.frames.length; i++) {
            try { restore(w.frames[i]); } catch (_) {}
          }
        } catch (_) {}
      }
      restore(window);
    })();
    """

  @MainActor static func configure(_ controller: WKUserContentController, enabled: Bool) {
    let scripts = controller.userScripts
    let owned = scripts.filter { $0.source.hasPrefix(marker) }
    if enabled {
      if owned.count == 1, let script = owned.first,
         script.source == source, script.injectionTime == .atDocumentStart,
         !script.isForMainFrameOnly { return }
    } else if owned.isEmpty { return }
    // WebKit's bridged array is a live view of the controller's scripts.
    // Materialize the scripts to keep before clearing its backing storage.
    let preserved = scripts.filter { !$0.source.hasPrefix(marker) }
    controller.removeAllUserScripts()
    for script in preserved {
      controller.addUserScript(script)
    }
    if enabled {
      controller.addUserScript(
        WKUserScript(
          source: source, injectionTime: .atDocumentStart,
          forMainFrameOnly: false, in: .page))
    }
  }
}
