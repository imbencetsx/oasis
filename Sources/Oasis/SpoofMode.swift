import WebKit

/// Best-effort suppression of activity signals exposed to page JavaScript.
/// This does not alter HTML/CSS, synthesize input, or conceal network identity.
enum SpoofMode {
  // Keep ownership compatible with earlier versions when replacing installed scripts.
  static let version = 15
  static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
  static let stateKey = "__oasisActivityPrivacy_v2"
  static let marker = "/* Oasis activity privacy"
  static let source = """
    /* Oasis activity privacy v\(version) */
    (() => {
      const key = '\(stateKey)';
      function install(w, traverse = true) {
        try {
          const d = w.document;
          const existing = w[key];
          if (existing?.document === d && existing.version === \(version)) {
            if (!traverse) return;
          } else {
            // Upgrade a live document from the previous implementation cleanly.
            existing?.restore();
            w.__oasisRestoreActivityPrivacy_v1?.();
            const patches = [];
            const cleanups = new Set();
            const sharingStops = new Map();
            function patch(object, name, descriptor) {
              const original = Object.getOwnPropertyDescriptor(object, name);
              patches.push({ object, name, original, descriptor: {
                ...descriptor, configurable: true, enumerable: original?.enumerable ?? false
              }});
            }
            // Keep JavaScript identity consistent with the HTTP User-Agent.
            for (const object of [w.Navigator.prototype, w.navigator]) {
              patch(object, 'userAgent', { get: () => '\(userAgent)' });
              patch(object, 'appVersion', { get: () => '\(userAgent)'.slice(8) });
              patch(object, 'platform', { get: () => 'Win32' });
              patch(object, 'vendor', { get: () => 'Google Inc.' });
            }
            const proto = w.Document.prototype;
            let fullscreenElement = null;
            for (const object of [proto, d]) {
              for (const name of ['hidden', 'webkitHidden'])
                patch(object, name, { get: () => false });
              for (const name of ['visibilityState', 'webkitVisibilityState'])
                patch(object, name, { get: () => 'visible' });
              patch(object, 'hasFocus', { value: function hasFocus() { return true; }, writable: true });
              for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'])
                patch(object, name, { get: () => fullscreenElement?.isConnected ? fullscreenElement : d.documentElement });
              for (const name of ['fullscreenEnabled', 'webkitFullscreenEnabled', 'webkitIsFullScreen', 'webkitFullScreen'])
                patch(object, name, { get: () => true });
              patch(object, 'exitFullscreen', { value: function exitFullscreen() {
                return w.Promise.resolve();
              }, writable: true });
              for (const name of ['webkitExitFullscreen', 'webkitCancelFullScreen'])
                patch(object, name, { value: function() {}, writable: true });
            }
            // Page fullscreen requests succeed without entering WebKit's native
            // fullscreen presentation or changing the browser window.
            patch(w.Element.prototype, 'requestFullscreen', { value: function requestFullscreen() {
              fullscreenElement = this;
              return w.Promise.resolve();
            }, writable: true });
            for (const name of ['webkitRequestFullscreen', 'webkitRequestFullScreen'])
              patch(w.Element.prototype, name, { value: function() {
                fullscreenElement = this;
              }, writable: true });
            \(WindowScreenSharing.source)
            function repair() {
              for (const p of patches) {
                try { Object.defineProperty(p.object, p.name, p.descriptor); } catch (_) {}
              }
            }
            const visibility = new Set(['visibilitychange', 'webkitvisibilitychange',
                                        'pagehide', 'pageshow', 'freeze', 'resume']);
            const boundary = new Set(['mouseenter', 'mouseleave', 'mouseover', 'mouseout',
                                     'pointerenter', 'pointerleave', 'pointerover', 'pointerout',
                                     'pointercancel', 'lostpointercapture', 'touchcancel']);
            const focus = new Set(['focus', 'blur', 'focusin', 'focusout']);
            const fullscreen = new Set(['fullscreenchange', 'webkitfullscreenchange',
                                        'fullscreenerror', 'webkitfullscreenerror']);
            function suppress(event) {
              // Repair after lifecycle transitions, including back/forward-cache restoration.
              if (visibility.has(event.type)) repair();
              // Focus events on controls can also disclose window deactivation.
              if (visibility.has(event.type) || boundary.has(event.type) || focus.has(event.type) || fullscreen.has(event.type)) {
                event.stopImmediatePropagation();
                event.stopPropagation();
              }
            }
            const blocked = new Set([...visibility, ...boundary, ...focus, ...fullscreen]);
            const eventProto = w.EventTarget.prototype;
            const nativeAdd = w.__oasisActivityNativeAdd ?? eventProto.addEventListener;
            Object.defineProperty(w, '__oasisActivityNativeAdd', {
              value: nativeAdd, configurable: true
            });
            const nativeRemove = w.__oasisActivityNativeRemove ?? eventProto.removeEventListener;
            Object.defineProperty(w, '__oasisActivityNativeRemove', {
              value: nativeRemove, configurable: true
            });
            const nativeDispatch = eventProto.dispatchEvent;
            // Wrapper identity survives toggles so removeEventListener and once/AbortSignal
            // retain their native behavior. Off mode forwards to the original callback.
            const wrappers = w.__oasisActivityListenerWrappers ?? new WeakMap();
            Object.defineProperty(w, '__oasisActivityListenerWrappers', {
              value: wrappers, configurable: true
            });
            function wrapped(listener) {
              if (!listener || (typeof listener !== 'function' && typeof listener !== 'object')) return listener;
              let result = wrappers.get(listener);
              if (!result) {
                result = function(event) {
                  if (w[key] && blocked.has(event.type)) return;
                  if (typeof listener === 'function') return listener.call(this, event);
                  return listener.handleEvent?.(event);
                };
                wrappers.set(listener, result);
              }
              return result;
            }
            patch(eventProto, 'addEventListener', { writable: true, value: function(type, listener, options) {
              return nativeAdd.call(this, type, blocked.has(String(type)) ? wrapped(listener) : listener, options);
            }});
            patch(eventProto, 'removeEventListener', { writable: true, value: function(type, listener, options) {
              nativeRemove.call(this, type, listener, options);
              const wrapper = listener && wrappers.get(listener);
              if (wrapper) nativeRemove.call(this, type, wrapper, options);
            }});
            patch(eventProto, 'dispatchEvent', { writable: true, value: function(event) {
              if (blocked.has(event?.type)) return true;
              return nativeDispatch.call(this, event);
            }});
            const handlers = [];
            const handlerRecords = new WeakMap();
            const originals = new WeakMap();
            // onfocus/onpointerleave handlers do not go through addEventListener.
            for (const object of [w, w.Document.prototype, w.HTMLElement.prototype,
                                  w.SVGElement?.prototype]) {
              if (!object) continue;
              for (const type of blocked) {
                const name = 'on' + type;
                const descriptor = Object.getOwnPropertyDescriptor(object, name);
                if (!descriptor?.set || !descriptor?.get || !descriptor.configurable) continue;
                patch(object, name, {
                  get: function() {
                    const value = descriptor.get.call(this);
                    return originals.get(value) ?? value;
                  },
                  set: function(listener) {
                    const wrapper = typeof listener === 'function' ? wrapped(listener) : listener;
                    if (typeof wrapper === 'function') originals.set(wrapper, listener);
                    let records = handlerRecords.get(this);
                    if (!records) {
                      records = new Map(); handlerRecords.set(this, records);
                      handlers.push(new WeakRef(this));
                    }
                    records.set(name, {descriptor, wrapper, listener});
                    descriptor.set.call(this, wrapper);
                  }
                });
              }
            }
            // A parent can inspect a newly created about:blank frame synchronously,
            // before its load event or a MutationObserver callback.
            for (const frameProto of [w.HTMLIFrameElement.prototype, w.HTMLFrameElement?.prototype]) {
              if (!frameProto) continue;
              for (const name of ['contentWindow', 'contentDocument']) {
                const descriptor = Object.getOwnPropertyDescriptor(frameProto, name);
                if (!descriptor?.get || !descriptor.configurable) continue;
                patch(frameProto, name, { get: function() {
                  const value = descriptor.get.call(this);
                  try { install(name === 'contentWindow' ? value : value?.defaultView, false); } catch (_) {}
                  return value;
                }});
              }
            }
            const types = [...blocked];
            for (const type of types) nativeAdd.call(w, type, suppress, true);
            const state = { version: \(version), document: d, repair,
              stopSharing(token) { sharingStops.get(token)?.(); }, restore() {
              for (const cleanup of [...cleanups]) cleanup();
              for (const type of types) nativeRemove.call(w, type, suppress, true);
              for (const reference of handlers) {
                const target = reference.deref();
                if (!target) continue;
                for (const h of handlerRecords.get(target).values()) {
                  if (h.descriptor.get.call(target) === h.wrapper)
                    h.descriptor.set.call(target, h.listener);
                }
              }
              for (const p of [...patches].reverse()) {
                try {
                  // Keep callback identity stable across toggles so re-adding a listener
                  // while off cannot register its original alongside its wrapper.
                  if (p.object === eventProto && (p.name === 'addEventListener' || p.name === 'removeEventListener')) continue;
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
          if (!traverse) return;
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
      function restore(w, traverse = true) {
        try {
          w['\(stateKey)']?.restore();
          w.__oasisRestoreActivityPrivacy_v1?.();
          if (!traverse) return;
          for (let i = 0; i < w.frames.length; i++) {
            try { restore(w.frames[i]); } catch (_) {}
          }
        } catch (_) {}
      }
      restore(window);
    })();
    """

  // Native frame identities already enumerate every document. Do not re-walk
  // descendants for each frame, which would repeatedly visit nested frames.
  static let frameSource = source.replacingOccurrences(of: "install(window);", with: "install(window, false);")
  static let frameRestoreSource = restoreSource.replacingOccurrences(of: "restore(window);", with: "restore(window, false);")

  @MainActor static func configure(_ controller: WKUserContentController, enabled: Bool) {
    // controller.userScripts bridges as a live view: removeAllUserScripts clears
    // previously fetched arrays (observed count dropping to 0, and out-of-bounds
    // crashes in objectAtIndex: when the backing storage is repurposed). Snapshot
    // into native storage first so no live reference survives past a mutation.
    let scripts: [WKUserScript] = controller.userScripts.map { $0 }
    let owned = scripts.filter { $0.source.hasPrefix(marker) }
    if enabled {
      if owned.count == 1, let script = owned.first,
         script.source == source, script.injectionTime == .atDocumentStart,
         !script.isForMainFrameOnly, scripts.last === script { return }
    } else if owned.isEmpty { return }
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
