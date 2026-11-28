import WebKit

/// Best-effort suppression of activity signals exposed to page JavaScript.
/// Every feature follows a `SpoofSettings` switch. This does not synthesize
/// input or conceal network identity beyond the reported browser identity.
enum SpoofMode {
  // Keep ownership compatible with earlier versions when replacing installed scripts.
  static let version = 18
  static let stateKey = "__oasisActivityPrivacy_v2"
  static let marker = "/* Oasis activity privacy"

  /// The default identity (Chrome on Windows), kept for callers without settings.
  static var userAgent: String { SpoofSettings().identity!.userAgent }

  /// Builds the page-world script for one set of preferences.
  /// - Parameter native: true for the Chromium engine, where DevTools already
  ///   provides the User-Agent, Client Hints, focus and viewport emulation.
  static func source(_ settings: SpoofSettings, resolution: CGSize, native: Bool = false) -> String {
    var options: [String: Any] = [
      "focusVisibility": settings.focusVisibility, "fullscreen": settings.fullscreen,
      "keyboard": settings.keyboard, "clipboardEvents": settings.clipboardEvents,
      "rightClick": settings.rightClick, "selection": settings.selection,
      "screenshare": settings.screenshare, "screenshareCursor": settings.screenshareCursor,
      "drm": settings.drm ? (settings.identity ?? SpoofIdentity(browser: .chrome, platform: .host)).drmKeySystems : NSNull(),
      "native": native,
      "resolution": ["width": Int(resolution.width), "height": Int(resolution.height)],
    ]
    options["identity"] = settings.identity?.scriptValue ?? NSNull()
    let data = (try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])) ?? Data("{}".utf8)
    return template
      .replacingOccurrences(of: "__OASIS_OPTIONS__", with: String(decoding: data, as: UTF8.self))
      .replacingOccurrences(of: "__OASIS_SHARING__", with: WindowScreenSharing.source)
  }

  // Native frame identities already enumerate every document. Do not re-walk
  // descendants for each frame, which would repeatedly visit nested frames.
  static func frameSource(_ settings: SpoofSettings, resolution: CGSize) -> String {
    source(settings, resolution: resolution).replacingOccurrences(of: "install(window);", with: "install(window, false);")
  }

  private static let template = #"""
    /* Oasis activity privacy v18 */
    (() => {
      const key = '__oasisActivityPrivacy_v2';
      const opt = __OASIS_OPTIONS__;
      const signature = JSON.stringify(opt);
      function install(w, traverse = true) {
        try {
          const d = w.document;
          const existing = w[key];
          if (existing?.document === d && existing.version === 18 && existing.signature === signature) {
            if (!traverse) return;
          } else {
            // Upgrade a live document cleanly. A settings change keeps an active
            // tab share running instead of ending it.
            existing?.restore({ keepSharing: true });
            w.__oasisRestoreActivityPrivacy_v1?.();
            const patches = [];
            const cleanups = new Set();
            const selectionStyles = new Map();
            const persistent = (name, create) => {
              if (!Object.hasOwn(w, name)) Object.defineProperty(w, name, { value: create(), configurable: true });
              return w[name];
            };
            const sharingStops = persistent('__oasisSharingStops', () => new Map());
            function patch(object, name, descriptor) {
              if (!object) return;
              const original = Object.getOwnPropertyDescriptor(object, name);
              patches.push({ object, name, original, descriptor: {
                ...descriptor, configurable: true, enumerable: original?.enumerable ?? false
              }});
            }
            const proto = w.Document.prototype;
            const nativeHasFocus = proto.hasFocus;

            // Browser identity and operating system. Chromium receives the same
            // identity natively through DevTools, including Client Hints headers.
            const identity = opt.identity;
            if (identity) {
              for (const object of [w.Navigator.prototype, w.navigator]) {
                if (!opt.native) {
                  patch(object, 'userAgent', { get: () => identity.userAgent });
                  patch(object, 'appVersion', { get: () => identity.appVersion });
                  patch(object, 'platform', { get: () => identity.platform });
                }
                if (!opt.native || identity.vendor !== 'Google Inc.')
                  patch(object, 'vendor', { get: () => identity.vendor });
              }
              if (!identity.hasUad) {
                if ('userAgentData' in w.navigator)
                  patch(w.Navigator.prototype, 'userAgentData', { get: () => undefined });
              } else if (!opt.native || !w.navigator.userAgentData) {
                // Chromium normally provides this natively from the DevTools override.
                const brands = identity.brands;
                const data = {
                  brands, mobile: false, platform: identity.uadPlatform,
                  async getHighEntropyValues(hints = []) {
                    const values = { brands, mobile: false, platform: identity.uadPlatform };
                    if (hints.includes('platformVersion')) values.platformVersion = identity.platformVersion;
                    if (hints.includes('architecture')) values.architecture = 'x86';
                    if (hints.includes('model')) values.model = '';
                    if (hints.includes('uaFullVersion')) values.uaFullVersion = identity.fullVersion;
                    if (hints.includes('fullVersionList')) values.fullVersionList = identity.fullVersionList;
                    if (hints.includes('bitness')) values.bitness = '64';
                    if (hints.includes('wow64')) values.wow64 = false;
                    return values;
                  },
                  toJSON() { return { brands, mobile: false, platform: identity.uadPlatform }; }
                };
                patch(w.Navigator.prototype, 'userAgentData', { get: () => data });
              }
              if (identity.hasChromeObject) {
                if (!w.chrome?.app) {
                  const now = () => Date.now() / 1000;
                  patch(w, 'chrome', { writable: true, value: Object.assign({}, w.chrome, {
                    app: {
                      isInstalled: false,
                      InstallState: { DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed' },
                      RunningState: { CANNOT_RUN: 'cannot_run', READY_TO_RUN: 'ready_to_run', RUNNING: 'running' },
                      getDetails: () => null, getIsInstalled: () => false, runningState: () => 'cannot_run'
                    },
                    csi: () => ({}),
                    loadTimes: () => ({
                      requestTime: now() - 1, startLoadTime: now() - 1, commitLoadTime: now() - 0.8,
                      finishDocumentLoadTime: now() - 0.5, firstPaintTime: now() - 0.6, firstPaintAfterLoadTime: 0,
                      navigationType: 'Other', wasFetchedViaSpdy: false, wasNpnNegotiated: false,
                      npnNegotiatedProtocol: 'unknown', wasAlternateProtocolAvailable: false, connectionInfo: 'unknown'
                    })
                  })});
                }
              } else if ('chrome' in w) {
                patch(w, 'chrome', { writable: true, value: undefined });
              }
            }

            // Focus and document visibility.
            if (opt.focusVisibility) {
              for (const object of [proto, d]) {
                for (const name of ['hidden', 'webkitHidden'])
                  patch(object, name, { get: () => false });
                for (const name of ['visibilityState', 'webkitVisibilityState'])
                  patch(object, name, { get: () => 'visible' });
                patch(object, 'hasFocus', { value: function hasFocus() { return true; }, writable: true });
              }
            }

            // Fullscreen lock: the page always sees a full-screen document on a
            // display of the locked resolution, and never sees exit or re-entry.
            if (opt.fullscreen) {
              let fullscreenElement = null;
              const element = () => fullscreenElement?.isConnected ? fullscreenElement : d.documentElement;
              for (const object of [proto, d]) {
                for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'])
                  patch(object, name, { get: element });
                for (const name of ['fullscreenEnabled', 'webkitFullscreenEnabled', 'webkitIsFullScreen', 'webkitFullScreen'])
                  patch(object, name, { get: () => true });
                if ('fullscreen' in proto) patch(object, 'fullscreen', { get: () => true });
              }
              const settle = result => result && typeof result.catch === 'function'
                ? result.catch(() => {}) : w.Promise.resolve();
              const nativeExit = proto.exitFullscreen;
              patch(proto, 'exitFullscreen', { writable: true, value: function exitFullscreen() {
                if (!opt.native) return w.Promise.resolve();
                try { return settle(nativeExit?.call(this)); } catch (_) { return w.Promise.resolve(); }
              }});
              for (const name of ['webkitExitFullscreen', 'webkitCancelFullScreen']) {
                const native = proto[name];
                patch(proto, name, { writable: true, value: function() {
                  if (opt.native) try { native?.call(this); } catch (_) {}
                }});
              }
              // Chromium enters real fullscreen as in a normal browser. WebKit
              // requests succeed without changing the browser window.
              const nativeRequest = w.Element.prototype.requestFullscreen;
              patch(w.Element.prototype, 'requestFullscreen', { writable: true, value: function requestFullscreen(...args) {
                fullscreenElement = this;
                if (!opt.native) return w.Promise.resolve();
                try { return settle(nativeRequest?.apply(this, args)); } catch (_) { return w.Promise.resolve(); }
              }});
              for (const name of ['webkitRequestFullscreen', 'webkitRequestFullScreen']) {
                const native = w.Element.prototype[name];
                patch(w.Element.prototype, name, { writable: true, value: function(...args) {
                  fullscreenElement = this;
                  if (opt.native) try { native?.apply(this, args); } catch (_) {}
                }});
              }
              // Chromium renders the page at the locked resolution (DevTools device
              // metrics), so the viewport matches it natively. WebKit cannot emulate
              // a viewport; there the display follows the live viewport instead.
              const width = () => opt.native ? opt.resolution.width : w.innerWidth;
              const height = () => opt.native ? opt.resolution.height : w.innerHeight;
              for (const object of [w.Screen.prototype, w.screen]) {
                for (const [name, value] of Object.entries({
                  width, height, availWidth: width, availHeight: height,
                  availLeft: () => 0, availTop: () => 0, left: () => 0, top: () => 0,
                  colorDepth: () => 24, pixelDepth: () => 24, isExtended: () => false
                })) {
                  if (name in w.screen || ['width', 'height', 'isExtended'].includes(name)) patch(object, name, { get: value });
                }
              }
              const orientation = w.ScreenOrientation?.prototype;
              if (orientation) {
                patch(orientation, 'type', { get: () => 'landscape-primary' });
                patch(orientation, 'angle', { get: () => 0 });
              }
              for (const [name, value] of Object.entries({
                outerWidth: width, outerHeight: height,
                screenX: () => 0, screenY: () => 0, screenLeft: () => 0,
                screenTop: () => 0, fullScreen: () => true
              })) patch(w, name, { get: value });
              const mediaProto = w.MediaQueryList?.prototype;
              const nativeMatches = mediaProto && Object.getOwnPropertyDescriptor(mediaProto, 'matches')?.get;
              const nativeMatchMedia = w.matchMedia;
              if (nativeMatches && nativeMatchMedia) {
                patch(mediaProto, 'matches', { get: function() {
                  const query = this.media.replace(
                    /\(\s*display-mode\s*:\s*([a-z-]+)\s*\)/gi,
                    (_, mode) => mode.toLowerCase() === 'fullscreen' ? '(min-width: 0px)' : '(max-width: -1px)');
                  return query === this.media ? nativeMatches.call(this)
                    : nativeMatches.call(nativeMatchMedia.call(w, query));
                }});
              }
            }

            // Text selection: page-facing selection readers report nothing, while
            // Chromium keeps the real selection for copying and editing.
            if (opt.selection) {
              let nativeSelection = null;
              try { nativeSelection = w.getSelection?.(); } catch (_) {}
              const selectionProto = w.Selection?.prototype;
              if (nativeSelection && selectionProto) {
                for (const [name, value] of Object.entries({
                  anchorNode: null, anchorOffset: 0, focusNode: null, focusOffset: 0,
                  baseNode: null, baseOffset: 0, extentNode: null, extentOffset: 0,
                  isCollapsed: true, rangeCount: 0, type: 'None', direction: 'none'
                })) {
                  const original = Object.getOwnPropertyDescriptor(selectionProto, name);
                  if (original?.get) patch(selectionProto, name, { get: function() {
                    return this === nativeSelection ? value : original.get.call(this);
                  }});
                }
                for (const [name, replacement] of Object.entries({
                  toString: () => '', containsNode: () => false, getComposedRanges: () => [],
                  getRangeAt: () => { throw new w.DOMException('The selection has no ranges.', 'IndexSizeError'); }
                })) {
                  const original = Object.getOwnPropertyDescriptor(selectionProto, name);
                  if (typeof original?.value === 'function') patch(selectionProto, name, { writable: true, value: function(...args) {
                    return this === nativeSelection ? replacement() : original.value.apply(this, args);
                  }});
                }
              }
              for (const constructor of [w.HTMLInputElement, w.HTMLTextAreaElement]) {
                if (!constructor?.prototype) continue;
                for (const name of ['selectionStart', 'selectionEnd', 'selectionDirection']) {
                  const original = Object.getOwnPropertyDescriptor(constructor.prototype, name);
                  if (original?.get) patch(constructor.prototype, name, { set: original.set, get: function() {
                    const value = original.get.call(this);
                    return this.ownerDocument === d && value !== null ? (name === 'selectionDirection' ? 'none' : 0) : value;
                  }});
                }
              }
            }

            if (opt.screenshare) {
              __OASIS_SHARING__
            }

            // EME / DRM capability spoofing: report the key systems expected for
            // the spoofed browser and OS without requiring a bundled CDM.
            if (Array.isArray(opt.drm) && w.Navigator?.prototype) {
              const allowedSystems = new Set(opt.drm);
              const filterCapabilities = list => {
                if (list === undefined) return [];
                if (!Array.isArray(list)) return null;
                return list.filter(item => item && typeof item.contentType === 'string' && item.contentType.includes('/'))
                  .map(item => ({
                    contentType: item.contentType,
                    robustness: typeof item.robustness === 'string' ? item.robustness : '',
                    encryptionScheme: item.encryptionScheme ?? null
                  }));
              };
              const matchConfig = configs => {
                for (const raw of configs) {
                  if (!raw || typeof raw !== 'object') continue;
                  const video = filterCapabilities(raw.videoCapabilities);
                  const audio = filterCapabilities(raw.audioCapabilities);
                  if (video === null || audio === null) continue;
                  if (Array.isArray(raw.videoCapabilities) && raw.videoCapabilities.length > 0 && video.length === 0) continue;
                  if (Array.isArray(raw.audioCapabilities) && raw.audioCapabilities.length > 0 && audio.length === 0) continue;
                  return {
                    label: typeof raw.label === 'string' ? raw.label : '',
                    initDataTypes: Array.isArray(raw.initDataTypes) ? raw.initDataTypes.map(String) : ['cenc'],
                    audioCapabilities: audio,
                    videoCapabilities: video,
                    distinctiveIdentifier: raw.distinctiveIdentifier === 'required' ? 'required' : 'optional',
                    persistentState: raw.persistentState === 'required' ? 'required' : 'optional',
                    sessionTypes: Array.isArray(raw.sessionTypes) && raw.sessionTypes.length ? raw.sessionTypes.map(String) : ['temporary']
                  };
                }
                return null;
              };
              const createSessionStub = () => {
                const session = Object.create(w.MediaKeySession?.prototype ?? Object.prototype);
                const statuses = new w.Map();
                const listeners = new Map();
                let sessionId = '';
                let onMessage = null;
                let onKeyStatusesChange = null;
                let resolveClosed;
                const closed = new w.Promise(resolve => { resolveClosed = resolve; });
                const emit = (type, event) => {
                  if (type === 'message' && typeof onMessage === 'function') {
                    try { onMessage.call(session, event); } catch (_) {}
                  } else if (type === 'keystatuseschange' && typeof onKeyStatusesChange === 'function') {
                    try { onKeyStatusesChange.call(session, event); } catch (_) {}
                  }
                  for (const fn of [...(listeners.get(type) ?? [])]) {
                    try {
                      if (typeof fn === 'function') fn.call(session, event);
                      else fn?.handleEvent?.(event);
                    } catch (_) {}
                  }
                };
                Object.defineProperties(session, {
                  sessionId: { get: () => sessionId, enumerable: true },
                  expiration: { value: NaN, enumerable: true },
                  closed: { value: closed, enumerable: true },
                  keyStatuses: { value: statuses, enumerable: true },
                  onmessage: { get: () => onMessage, set: v => { onMessage = v; }, enumerable: true },
                  onkeystatuseschange: { get: () => onKeyStatusesChange, set: v => { onKeyStatusesChange = v; }, enumerable: true },
                  generateRequest: {
                    writable: true,
                    value: (initDataType, initData) => {
                      if (!initDataType || !initData) {
                        return w.Promise.reject(new w.TypeError('initDataType and initData are required.'));
                      }
                      if (!sessionId) sessionId = Math.random().toString(16).slice(2, 18).toUpperCase();
                      const payload = new w.Uint8Array([8, 4]).buffer;
                      const event = typeof w.MediaKeyMessageEvent === 'function'
                        ? new w.MediaKeyMessageEvent('message', { messageType: 'license-request', message: payload })
                        : Object.assign(new w.Event('message'), { messageType: 'license-request', message: payload });
                      queueMicrotask(() => emit('message', event));
                      return w.Promise.resolve();
                    }
                  },
                  load: { value: () => w.Promise.resolve(false), writable: true },
                  update: {
                    writable: true,
                    value: () => {
                      statuses.set(new w.Uint8Array(16).buffer, 'usable');
                      queueMicrotask(() => emit('keystatuseschange', new w.Event('keystatuseschange')));
                      return w.Promise.resolve();
                    }
                  },
                  close: {
                    writable: true,
                    value: () => {
                      resolveClosed?.('closed-by-application');
                      return w.Promise.resolve();
                    }
                  },
                  remove: { value: () => w.Promise.resolve(), writable: true },
                  addEventListener: {
                    writable: true,
                    value: (type, fn) => {
                      if (!fn) return;
                      let set = listeners.get(type);
                      if (!set) { set = new Set(); listeners.set(type, set); }
                      set.add(fn);
                    }
                  },
                  removeEventListener: {
                    writable: true,
                    value: (type, fn) => { listeners.get(type)?.delete(fn); }
                  },
                  dispatchEvent: {
                    writable: true,
                    value: event => { emit(event.type, event); return true; }
                  }
                });
                return session;
              };
              const stubMediaKeys = new WeakSet();
              const elementMediaKeys = new WeakMap();
              const createKeysStub = () => {
                const keys = Object.create(w.MediaKeys?.prototype ?? Object.prototype);
                Object.defineProperties(keys, {
                  createSession: { value: () => createSessionStub(), writable: true },
                  setServerCertificate: { value: () => w.Promise.resolve(true), writable: true }
                });
                stubMediaKeys.add(keys);
                return keys;
              };
              const mediaProto = w.HTMLMediaElement?.prototype;
              if (mediaProto) {
                const nativeSetMediaKeys = mediaProto.setMediaKeys;
                const nativeMediaKeysDesc = Object.getOwnPropertyDescriptor(mediaProto, 'mediaKeys');
                if (typeof nativeSetMediaKeys === 'function') {
                  patch(mediaProto, 'setMediaKeys', {
                    writable: true,
                    value: function setMediaKeys(keys) {
                      if (keys && stubMediaKeys.has(keys)) {
                        elementMediaKeys.set(this, keys);
                        return w.Promise.resolve();
                      }
                      elementMediaKeys.delete(this);
                      return nativeSetMediaKeys.call(this, keys);
                    }
                  });
                }
                if (nativeMediaKeysDesc?.get) {
                  patch(mediaProto, 'mediaKeys', {
                    get: function() {
                      return elementMediaKeys.get(this) ?? nativeMediaKeysDesc.get.call(this);
                    }
                  });
                }
              }
              const createAccessStub = (system, config) => {
                const access = Object.create(w.MediaKeySystemAccess?.prototype ?? Object.prototype);
                Object.defineProperties(access, {
                  keySystem: { get: () => system, enumerable: true },
                  getConfiguration: { value: () => structuredClone(config), writable: true },
                  createMediaKeys: { value: () => w.Promise.resolve(createKeysStub()), writable: true }
                });
                return access;
              };
              patch(w.Navigator.prototype, 'requestMediaKeySystemAccess', {
                writable: true,
                value: function requestMediaKeySystemAccess(keySystem, supportedConfigurations) {
                  if (arguments.length < 2 || typeof keySystem !== 'string' || !keySystem) {
                    return w.Promise.reject(new w.TypeError('Failed to execute \'requestMediaKeySystemAccess\' on \'Navigator\': 2 arguments required.'));
                  }
                  let configs;
                  try { configs = Array.from(supportedConfigurations); } catch (_) {
                    return w.Promise.reject(new w.TypeError('supportedConfigurations must be a sequence.'));
                  }
                  if (!configs.length) {
                    return w.Promise.reject(new w.TypeError('supportedConfigurations must not be empty.'));
                  }
                  if (!allowedSystems.has(keySystem)) {
                    return w.Promise.reject(new w.DOMException('Unsupported keySystem or supportedConfigurations.', 'NotSupportedError'));
                  }
                  const matched = matchConfig(configs);
                  if (!matched) {
                    return w.Promise.reject(new w.DOMException('Unsupported keySystem or supportedConfigurations.', 'NotSupportedError'));
                  }
                  return w.Promise.resolve(createAccessStub(keySystem, matched));
                }
              });
            }

            function repair() {
              for (const p of patches) {
                try { Object.defineProperty(p.object, p.name, p.descriptor); } catch (_) {}
              }
            }

            const visibilityTypes = new Set(['visibilitychange', 'webkitvisibilitychange',
                                             'pagehide', 'pageshow', 'freeze', 'resume']);
            const focusTypes = new Set(['focus', 'blur', 'focusin', 'focusout']);
            const boundaryTypes = new Set(['mouseenter', 'mouseleave', 'mouseover', 'mouseout',
                                           'pointerenter', 'pointerleave', 'pointerover', 'pointerout']);
            const leaveTypes = new Set(['mouseleave', 'mouseout', 'pointerleave', 'pointerout',
                                        'pointercancel', 'lostpointercapture', 'touchcancel']);
            const fullscreenTypes = new Set(['fullscreenchange', 'webkitfullscreenchange',
                                             'fullscreenerror', 'webkitfullscreenerror']);
            const selectionTypes = new Set(['selectionchange', 'selectstart', 'select']);
            const keyTypes = new Set(['keydown', 'keyup', 'keypress']);
            const clipboardTypes = new Set(['copy', 'cut', 'paste', 'beforecopy', 'beforecut', 'beforepaste']);
            // Listener wrappers cover every type that any setting can filter, so
            // changing settings later still applies to listeners added earlier.
            const filtered = new Set([...visibilityTypes, ...focusTypes, ...boundaryTypes, ...leaveTypes,
              ...fullscreenTypes, ...selectionTypes, ...keyTypes, ...clipboardTypes, 'contextmenu', 'resize']);

            const editable = element => {
              if (!element || element.nodeType !== 1) return false;
              const tag = (element.tagName || '').toUpperCase();
              if (tag === 'TEXTAREA') return !element.readOnly && !element.disabled;
              if (tag === 'INPUT') {
                const type = (element.type || 'text').toLowerCase();
                return ['text', 'password', 'search', 'email', 'url', 'tel', 'number', ''].includes(type) &&
                  !element.readOnly && !element.disabled;
              }
              return !!element.isContentEditable || element.ownerDocument?.designMode === 'on';
            };
            const writing = target => {
              let element = target;
              if (element?.nodeType === 3) element = element.parentElement;
              return editable(element) || editable(d.activeElement);
            };
            // Characters typed into a text box reach the page; shortcuts and other keys do not.
            const characterKey = (event, target) => {
              const altGraph = !!event.getModifierState?.('AltGraph');
              if ((event.ctrlKey && !altGraph) || event.metaKey || (event.altKey && !altGraph) || !event.key) return false;
              if (event.key.length === 1) return true;
              if (event.key !== 'Enter') return false;
              let element = target;
              if (element?.nodeType === 3) element = element.parentElement;
              return element?.tagName === 'TEXTAREA' || !!element?.isContentEditable || element?.ownerDocument?.designMode === 'on';
            };

            const decisions = new WeakMap();
            const awayTargets = new WeakSet();
            function decide(event) {
              const type = event.type, trusted = event.isTrusted;
              if (opt.focusVisibility) {
                if (visibilityTypes.has(type)) return true;
                if (focusTypes.has(type)) {
                  const target = event.target;
                  if (target === w || target === d) return true;
                  // Moving focus between inputs still works. Focus lost or regained
                  // only because the browser window changed stays hidden.
                  if ((type === 'blur' || type === 'focusout') && trusted && !nativeHasFocus.call(d)) {
                    if (target) awayTargets.add(target);
                    return true;
                  }
                  if ((type === 'focus' || type === 'focusin') && target && awayTargets.has(target)) {
                    if (type === 'focusin') awayTargets.delete(target);
                    return true;
                  }
                  return false;
                }
                // The pointer leaving the page is never reported.
                if (trusted && leaveTypes.has(type) && (!boundaryTypes.has(type) || !event.relatedTarget)) return true;
              }
              if (opt.fullscreen && fullscreenTypes.has(type)) return true;
              if (!trusted) return false;
              if (opt.selection && (boundaryTypes.has(type) || selectionTypes.has(type))) return true;
              if (opt.fullscreen && opt.native && type === 'resize') return true;
              if (opt.keyboard && keyTypes.has(type)) {
                const target = event.composedPath?.()[0] || event.target;
                return !(writing(target) && characterKey(event, target));
              }
              if (opt.clipboardEvents && clipboardTypes.has(type)) return true;
              return opt.rightClick && type === 'contextmenu';
            }
            function blocks(event) {
              if (!event || !filtered.has(event.type)) return false;
              let decision = decisions.get(event);
              if (decision === undefined) { decision = decide(event); decisions.set(event, decision); }
              return decision;
            }
            // Script-dispatched events reach listeners unless they disclose
            // document visibility, window focus or fullscreen changes.
            function blocksDispatch(target, event) {
              const type = event?.type;
              if (opt.focusVisibility && (visibilityTypes.has(type) || (focusTypes.has(type) && (target === w || target === d)))) return true;
              return opt.fullscreen && fullscreenTypes.has(type);
            }
            const neutralize = event => {
              try {
                Object.defineProperty(event, 'preventDefault', { configurable: true, value() {} });
                Object.defineProperty(event, 'returnValue', { configurable: true, get: () => true, set() {} });
              } catch (_) {}
            };
            function suppress(event) {
              // Repair after lifecycle transitions, including back/forward-cache restoration.
              if (visibilityTypes.has(event.type)) repair();
              // The page cannot prevent the native context menu.
              if (opt.rightClick && event.type === 'contextmenu' && event.isTrusted) neutralize(event);
              if (blocks(event)) {
                event.stopImmediatePropagation();
                event.stopPropagation();
              }
            }
            // Restore text selection and input focus on the clicked branch only:
            // user-select:none is relaxed and mouse-down cancellation is ignored.
            function allowSelection(event) {
              if (!event.isTrusted || event.button !== 0) return;
              let element = event.composedPath?.()[0] || event.target;
              if (element?.nodeType === 3) element = element.parentElement;
              while (element?.style && element.ownerDocument === d) {
                const computed = w.getComputedStyle?.(element);
                if (computed?.userSelect === 'none' || computed?.webkitUserSelect === 'none') {
                  let properties = selectionStyles.get(element);
                  if (!properties) { properties = new Map(); selectionStyles.set(element, properties); }
                  for (const property of ['user-select', '-webkit-user-select']) {
                    if (!properties.has(property)) properties.set(property, {
                      value: element.style.getPropertyValue(property),
                      priority: element.style.getPropertyPriority(property)
                    });
                    element.style.setProperty(property, 'text', 'important');
                  }
                }
                element = element.parentElement || element.getRootNode?.().host;
              }
              neutralize(event);
            }

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
                  if (w[key]?.blocks?.(event)) return;
                  if (typeof listener === 'function') return listener.call(this, event);
                  return listener.handleEvent?.(event);
                };
                wrappers.set(listener, result);
              }
              return result;
            }
            patch(eventProto, 'addEventListener', { writable: true, value: function(type, listener, options) {
              return nativeAdd.call(this, type, filtered.has(String(type)) ? wrapped(listener) : listener, options);
            }});
            patch(eventProto, 'removeEventListener', { writable: true, value: function(type, listener, options) {
              nativeRemove.call(this, type, listener, options);
              const wrapper = listener && wrappers.get(listener);
              if (wrapper) nativeRemove.call(this, type, wrapper, options);
            }});
            patch(eventProto, 'dispatchEvent', { writable: true, value: function(event) {
              if (blocksDispatch(this, event)) return true;
              return nativeDispatch.call(this, event);
            }});
            const handlers = [];
            const handlerRecords = new WeakMap();
            const originals = new WeakMap();
            // onfocus/onkeydown/oncopy handlers do not go through addEventListener.
            for (const object of [w, w.Document.prototype, w.HTMLElement.prototype,
                                  w.SVGElement?.prototype]) {
              if (!object) continue;
              for (const type of filtered) {
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
            const listeners = [...filtered].map(type => [type, suppress]);
            if (opt.selection) listeners.push(['pointerdown', allowSelection], ['mousedown', allowSelection]);
            for (const [type, listener] of listeners) nativeAdd.call(w, type, listener, true);
            const state = { version: 18, signature, document: d, repair, blocks,
              stopSharing(token) { sharingStops.get(token)?.(); },
              restore({ keepSharing = false } = {}) {
              for (const cleanup of [...cleanups]) cleanup();
              if (!keepSharing) for (const stop of [...sharingStops.values()]) stop();
              for (const [type, listener] of listeners) nativeRemove.call(w, type, listener, true);
              for (const reference of handlers) {
                const target = reference.deref();
                if (!target) continue;
                for (const h of handlerRecords.get(target).values()) {
                  if (h.descriptor.get.call(target) === h.wrapper)
                    h.descriptor.set.call(target, h.listener);
                }
              }
              for (const [element, properties] of selectionStyles) {
                for (const [property, original] of properties) {
                  if (element.style.getPropertyValue(property) !== 'text' ||
                      element.style.getPropertyPriority(property) !== 'important') continue;
                  if (original.value) element.style.setProperty(property, original.value, original.priority);
                  else element.style.removeProperty(property);
                }
              }
              selectionStyles.clear();
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
    """#

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

  static let frameRestoreSource = restoreSource.replacingOccurrences(of: "restore(window);", with: "restore(window, false);")

  /// Installs (or removes) the document-start script for the WebKit engine.
  @MainActor static func configure(_ controller: WKUserContentController, source: String?) {
    // controller.userScripts bridges as a live view: removeAllUserScripts clears
    // previously fetched arrays (observed count dropping to 0, and out-of-bounds
    // crashes in objectAtIndex: when the backing storage is repurposed). Snapshot
    // into native storage first so no live reference survives past a mutation.
    let scripts: [WKUserScript] = controller.userScripts.map { $0 }
    let owned = scripts.filter { $0.source.hasPrefix(marker) }
    if let source {
      if owned.count == 1, let script = owned.first,
         script.source == source, script.injectionTime == .atDocumentStart,
         !script.isForMainFrameOnly, scripts.last === script { return }
    } else if owned.isEmpty { return }
    let preserved = scripts.filter { !$0.source.hasPrefix(marker) }
    controller.removeAllUserScripts()
    for script in preserved {
      controller.addUserScript(script)
    }
    if let source {
      controller.addUserScript(
        WKUserScript(
          source: source, injectionTime: .atDocumentStart,
          forMainFrameOnly: false, in: .page))
    }
  }
}
