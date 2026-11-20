import AppKit

/// Tracks windows animating into or out of fullscreen. The animation moves
/// the window between Spaces and through many sizes; cursor containment must
/// not mistake it for the user leaving the page.
@MainActor enum FullscreenTransitions {
    /// Geometry keeps changing briefly after the "did" notification.
    static let settleTime: TimeInterval = 0.5
    /// A transition that never finishes stops counting after this long.
    static let maximumDuration: TimeInterval = 4

    private static var started: [ObjectIdentifier: Date] = [:]
    private static var finished: [ObjectIdentifier: Date] = [:]
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let id = (note.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { if let id { started[id] = Date(); finished[id] = nil } }
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let id = (note.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { if let id { started[id] = nil; finished[id] = Date() } }
            })
        }
    }

    /// True while the window is entering or leaving fullscreen, and shortly after.
    static func isSettling(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        let id = ObjectIdentifier(window)
        if let start = started[id], Date().timeIntervalSince(start) < maximumDuration { return true }
        if let end = finished[id], Date().timeIntervalSince(end) < settleTime { return true }
        return false
    }
}
