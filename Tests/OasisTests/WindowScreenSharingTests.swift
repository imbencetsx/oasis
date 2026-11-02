import Foundation
import Testing
import WebKit
@testable import Oasis

@Suite("Window screen sharing", .serialized)
@MainActor struct WindowScreenSharingTests {
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
            const cleanups = new Set();
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
              capabilities.logicalSurface === true && capabilities.cursor.includes('always') &&
              constraints.cursor === 'always' && clonedTrack.readyState === 'ended' && clone.readyState === 'ended' &&
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
            const d = document, cleanups = new Set();
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
