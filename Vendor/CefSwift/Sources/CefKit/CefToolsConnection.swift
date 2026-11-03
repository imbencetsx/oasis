import Foundation
import CCef

@MainActor final class CefToolsConnection {
    weak var browser: CefBrowser?
    var event: (@MainActor (String, [String: Any]) -> Void)?
    private var registration: UnsafeMutablePointer<cef_registration_t>?
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextID = 10000

    init(browser: CefBrowser) {
        self.browser = browser
        let observer = cefAllocate(cef_dev_tools_message_observer_t.self, owner: self)
        observer.pointee.on_dev_tools_message = { pointer, rawBrowser, bytes, size in
            defer { if let rawBrowser { cefRelease(UnsafeMutableRawPointer(rawBrowser)) } }
            guard let bytes, let owner = cefOwner(CefToolsConnection.self, pointer.map(UnsafeMutableRawPointer.init)) else { return 0 }
            let data = Data(bytes: bytes, count: size)
            MainActor.assumeIsolated { owner.receive(data) }
            return 0
        }
        browser.withHostInternal { host in
            registration = host.pointee.add_dev_tools_message_observer?(host, observer)
        }
        // CEF's C-to-C++ wrapper consumes the reference passed to registration.
    }

    func send(_ method: String, params: [String: Any]) async throws -> Data {
        guard registration != nil, let browser else { throw failure("Chromium page is closed.") }
        nextID += 1
        let id = nextID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            var accepted = false
            browser.withHostInternal { host in
                accepted = data.withUnsafeBytes { bytes in
                    host.pointee.send_dev_tools_message?(host, bytes.baseAddress, data.count) == 1
                }
            }
            if !accepted { pending.removeValue(forKey: id)?.resume(throwing: failure("Chromium rejected \(method).")) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                self.pending.removeValue(forKey: id)?.resume(throwing: self.failure("Chromium command timed out: \(method)"))
            }
        }
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: failure(error["message"] as? String ?? "Chromium command failed."))
            } else { continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)) }
        } else if let method = message["method"] as? String {
            event?(method, message["params"] as? [String: Any] ?? [:])
        }
    }

    func invalidate() {
        if let registration { cefRelease(UnsafeMutableRawPointer(registration)) }
        registration = nil
        let old = pending; pending = [:]
        for continuation in old.values { continuation.resume(throwing: failure("Chromium page closed.")) }
        event = nil
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "Oasis.Chromium", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
