import AppKit
import Testing
import WebKit
@testable import Oasis

@Suite("Window screen sharing", .serialized)
@MainActor struct WindowScreenSharingTests {
    @Test func webViewShareStaysOnItsOriginatingTab() async throws {
        let tab = try await loadedTab()
        tab.webView.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        tab.setTopInset(40)
        tab.webView.loadHTMLString("<title>Shared source</title><body style='margin:0;background:rgb(255,0,0)'></body>", baseURL: nil)
        for _ in 0..<100 {
            if tab.webView.title == "Shared source" && !tab.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let window = NSWindow(contentRect: tab.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.webView
        let activity = WindowCaptureActivity(preferences: tab.webView.configuration.preferences)
        let source = try WebViewCaptureSource(webView: tab.webView)
        defer { source.close(); activity.end(); window.close(); tab.close() }
        let initial = try await source.frame()
        #expect(initial.width == 320 && initial.height == 200)
        let red = try #require(NSBitmapImageRep(cgImage: initial).colorAt(x: 160, y: 100)?.usingColorSpace(.deviceRGB))
        #expect(red.redComponent > 0.9 && red.greenComponent < 0.1)
        // Replace the selected tab's view with a different page, as SwiftUI does.
        let otherTab = WKWebView(frame: tab.webView.frame)
        window.contentView = otherTab
        otherTab.loadHTMLString("<body style='background:blue'></body>", baseURL: nil)
        _ = try await tab.webView.evaluateJavaScript("document.body.style.background = 'rgb(0,255,0)';")
        var changed = false
        for _ in 0..<20 {
            let image = try await source.frame()
            let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 160, y: 100)?.usingColorSpace(.deviceRGB))
            if color.greenComponent > 0.9 && color.redComponent < 0.1 && color.blueComponent < 0.1 { changed = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(changed)
        #expect(tab.webView.window !== window)
        source.prepareForDisplay()
        window.contentView = tab.webView
        #expect(tab.webView.window === window)
    }

    @Test func backgroundSchedulingIsRestoredAfterTheLastShare() {
        let preferences = WKPreferences()
        preferences.inactiveSchedulingPolicy = .suspend
        let first = WindowCaptureActivity(preferences: preferences)
        let second = WindowCaptureActivity(preferences: preferences)
        #expect(preferences.inactiveSchedulingPolicy == .none)
        first.end()
        first.end()
        #expect(preferences.inactiveSchedulingPolicy == .none)
        second.end()
        #expect(preferences.inactiveSchedulingPolicy == .suspend)
    }

    @Test func temporaryFrameFailuresKeepSharingAliveAndRecover() async throws {
        let tab = try await loadedTab()
        defer { tab.close() }
        let result = try await tab.webView.callAsyncJavaScript("""
            const d = document, cleanups = new Set(), sharingStops = new Map(), pending = [];
            const fixture = d.createElement('canvas');
            fixture.width = 64; fixture.height = 48;
            const image = fixture.toDataURL('image/png');
            let frames = 0, ended = 0, mode = 'live';
            const bridge = {postMessage: async body => {
              if (body.action === 'begin') return {token: 'fixture', width: 64, height: 48};
              if (body.action === 'end') { ended++; return true; }
              frames++;
              if (mode === 'retry') return {retry: true};
              if (mode === 'error') throw new Error('WindowServer is switching desktops');
              if (mode === 'ended') return {ended: true};
              return image;
            }};
            const w = {
              navigator: {mediaDevices: {}, userActivation: {isActive: true}},
              HTMLCanvasElement, MediaStreamTrack, MediaStream, crypto, Image, Event, DOMException, TypeError,
              isSecureContext: true, devicePixelRatio: 1,
              setTimeout: callback => { pending.push(callback); return pending.length; }, clearTimeout: () => {},
              webkit: {messageHandlers: {oasisWindowShare: bridge}}
            };
            w.top = w;
            const patch = (object, name, descriptor) => Object.defineProperty(object, name, {...descriptor, configurable: true});
            \(WindowScreenSharing.source)
            const stream = await w.navigator.mediaDevices.getDisplayMedia({video: true});
            const track = stream.getVideoTracks()[0];
            let trackEnds = 0;
            track.addEventListener('ended', () => trackEnds++);
            for (const transient of ['retry', 'error', 'retry', 'live']) {
              mode = transient;
              await pending.shift()();
              if (track.readyState !== 'live' || ended || trackEnds || pending.length !== 1) return false;
            }
            const recovered = frames === 5;
            mode = 'ended';
            await pending.shift()();
            return recovered && track.readyState === 'ended' && ended === 1 && trackEnds === 1 &&
              pending.length === 0 && cleanups.size === 0;
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(result == true)
    }

    @Test func recordingKeepsItsInitialOriginScaleAndSize() throws {
        let framing = WebViewCaptureFraming(contentSize: CGSize(width: 100, height: 80))
        for size in [CGSize(width: 100, height: 80), CGSize(width: 200, height: 160), CGSize(width: 50, height: 40)] {
            let width = Int(size.width), height = Int(size.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    pixels[index + 2] = 255
                    pixels[index + 3] = 255
                    if (10..<14).contains(x) && (10..<14).contains(y) {
                        pixels[index] = 255
                        pixels[index + 2] = 0
                    }
                }
            }
            let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
            let source = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let image = try #require(framing.imageOnFixedCanvas(source))
            #expect(image.width == 100 && image.height == 80)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let marker = try #require(bitmap.colorAt(x: 11, y: 11)?.usingColorSpace(.deviceRGB))
            #expect(marker.redComponent > 0.99 && marker.blueComponent < 0.01)
            let corner = try #require(bitmap.colorAt(x: 90, y: 70)?.usingColorSpace(.deviceRGB))
            #expect(corner.blueComponent > 0.99)
            #expect(framing.scaledSourceSize(size) == size)
        }
    }

    @Test func transparentEdgesAndPaddingMatchTheWindowBackground() throws {
        let framing = WebViewCaptureFraming(contentSize: CGSize(width: 100, height: 80))
        let sourceWidth = 50, sourceHeight = 40
        var pixels = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth {
                let index = (y * sourceWidth + x) * 4
                pixels[index] = 24; pixels[index + 1] = 34; pixels[index + 2] = 44
                pixels[index + 3] = (x < 4 && y < 4) ? 0 : 255
                if pixels[index + 3] == 0 { pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 0 }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let source = try #require(CGImage(width: sourceWidth, height: sourceHeight, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: sourceWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let image = try #require(framing.imageOnFixedCanvas(source))
        let bitmap = NSBitmapImageRep(cgImage: image)
        for point in [(0, 0), (90, 70), (70, 10), (10, 60)] {
            let color = try #require(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
            #expect(abs(color.redComponent - 24.0 / 255) < 0.01)
            #expect(abs(color.greenComponent - 34.0 / 255) < 0.01)
            #expect(abs(color.blueComponent - 44.0 / 255) < 0.01)
        }
    }

    private func loadedTab() async throws -> BrowserTab {
        let tab = BrowserTab(isPrivate: true, spoofModeEnabled: true)
        tab.webView.loadHTMLString("<title>Window sharing</title>", baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 {
            if tab.webView.title == "Window sharing" && !tab.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(tab.webView.title == "Window sharing")
        return tab
    }

    @Test func displayMediaIsAvailableAndRestoresOnDisable() async throws {
        let tab = try await loadedTab()
        defer { tab.close() }
        #expect(try await tab.webView.evaluateJavaScript("typeof navigator.mediaDevices?.getDisplayMedia") as? String == "function")
        tab.setSpoofMode(false)
        #expect(try await tab.webView.evaluateJavaScript("!!navigator.mediaDevices && Object.hasOwn(navigator.mediaDevices, 'getDisplayMedia')") as? Bool == false)
        let denied = try await tab.webView.callAsyncJavaScript("""
            try {
              await window.webkit.messageHandlers.oasisWindowShare.postMessage({action: 'begin'});
              return false;
            } catch (error) { return String(error).includes('Spoof Mode'); }
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(denied == true)
        tab.setSpoofMode(true)
        #expect(try await tab.webView.evaluateJavaScript("Object.hasOwn(navigator.mediaDevices, 'getDisplayMedia')") as? Bool == true)
    }

    @Test func streamReportsMonitorWhileUsingWindowFramesAndStopsTheNativeSession() async throws {
        let tab = try await loadedTab()
        defer { tab.close() }
        // Exercise the actual canvas/MediaStream client with a deterministic frame
        // source. Native OS permission prompts are deliberately outside this test.
        let result = try await tab.webView.callAsyncJavaScript("""
            const d = document;
            const cleanups = new Set(), sharingStops = new Map();
            const calls = [];
            const fixture = d.createElement('canvas');
            fixture.width = 64; fixture.height = 48;
            fixture.getContext('2d').fillRect(0, 0, 64, 48);
            const frame = fixture.toDataURL('image/png');
            const bridge = {postMessage: async body => {
              calls.push(body.action);
              if (body.action === 'begin') return {token: 'fixture', width: 64, height: 48};
              if (body.action === 'frame') return frame;
              return true;
            }};
            const w = {
              navigator: {mediaDevices: {}, userActivation: {isActive: true}},
              HTMLCanvasElement, isSecureContext: true, DOMException, TypeError, Image, Event,
              MediaStreamTrack, MediaStream, crypto, devicePixelRatio: 2,
              setTimeout: window.setTimeout.bind(window), clearTimeout: window.clearTimeout.bind(window),
              webkit: {messageHandlers: {oasisWindowShare: bridge}}
            };
            w.top = w;
            const patch = (object, name, descriptor) => Object.defineProperty(object, name, {...descriptor, configurable: true});
            \(WindowScreenSharing.source)
            const stream = await w.navigator.mediaDevices.getDisplayMedia({video: true});
            const track = stream.getVideoTracks()[0];
            const settings = track.getSettings();
            const capabilities = track.getCapabilities();
            const constraints = track.getConstraints();
            const supported = w.navigator.mediaDevices.getSupportedConstraints();
            const clone = track.clone();
            const streamClone = stream.clone().clone();
            const clonedTrack = streamClone.getVideoTracks()[0];
            const metadata = [track, clone, clonedTrack].every(value =>
              value.label === 'Screen 1' && value.getSettings().displaySurface === 'monitor' &&
              value.getSettings().deviceId === settings.deviceId &&
              value.getCapabilities().displaySurface === 'monitor' &&
              value.getConstraints().displaySurface === 'monitor' &&
              MediaStreamTrack.prototype.getSettings.call(value).displaySurface === 'monitor');
            const unrelated = fixture.captureStream().getVideoTracks()[0];
            const isolated = unrelated.getSettings().displaySurface !== 'monitor' && unrelated.label !== 'Screen 1';
            unrelated.stop();
            const live = track.readyState === 'live' && stream.getAudioTracks().length === 0;
            track.stop(); track.stop();
            const clonesRemainLive = clone.readyState === 'live' && clonedTrack.readyState === 'live' &&
              !calls.includes('end');
            // Native Stop Sharing / mode restoration must stop every remaining clone.
            for (const cleanup of [...cleanups]) cleanup();
            return live && settings.displaySurface === 'monitor' && settings.width === 64 &&
              metadata && isolated && clonesRemainLive && settings.screenPixelRatio === 2 &&
              supported.displaySurface === true && supported.logicalSurface === true && supported.cursor === true &&
              settings.cursor === 'never' && capabilities.logicalSurface === true && capabilities.cursor.join(',') === 'never' &&
              constraints.cursor === 'never' && clonedTrack.readyState === 'ended' && clone.readyState === 'ended' &&
              track.readyState === 'ended' && cleanups.size === 0 &&
              calls.filter(action => action === 'begin').length === 1 &&
              calls.filter(action => action === 'end').length === 1;
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(result == true)
    }

    @Test func invalidRequestsNeverBeginNativeCapture() async throws {
        let tab = try await loadedTab()
        defer { tab.close() }
        let result = try await tab.webView.callAsyncJavaScript("""
            const d = document, cleanups = new Set(), sharingStops = new Map();
            let calls = 0;
            const w = {
              navigator: {mediaDevices: {}, userActivation: {isActive: false}},
              HTMLCanvasElement, isSecureContext: true, DOMException, TypeError,
              MediaStreamTrack, MediaStream,
              webkit: {messageHandlers: {oasisWindowShare: {postMessage: () => {calls++;}}}}
            };
            w.top = w;
            const patch = (object, name, descriptor) => Object.defineProperty(object, name, descriptor);
            \(WindowScreenSharing.source)
            const names = [];
            try { await w.navigator.mediaDevices.getDisplayMedia(); } catch (e) { names.push(e.name); }
            w.navigator.userActivation.isActive = true;
            try { await w.navigator.mediaDevices.getDisplayMedia({video: false}); } catch (e) { names.push(e.name); }
            w.isSecureContext = false;
            try { await w.navigator.mediaDevices.getDisplayMedia(); } catch (e) { names.push(e.name); }
            return calls === 0 && names.join(',') === 'InvalidStateError,TypeError,NotAllowedError';
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(result == true)
    }
}
