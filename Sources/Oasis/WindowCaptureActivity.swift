import Foundation
import WebKit

/// Keeps a user-started share running without changing idle tabs' scheduling.
@MainActor final class WindowCaptureActivity {
    private struct SchedulingRecord {
        let preferences: WKPreferences
        let originalPolicy: WKPreferences.InactiveSchedulingPolicy
        var count: Int
    }
    private static var scheduling: [ObjectIdentifier: SchedulingRecord] = [:]
    private let key: ObjectIdentifier
    private var activity: NSObjectProtocol?

    init(preferences: WKPreferences) {
        key = ObjectIdentifier(preferences)
        if var record = Self.scheduling[key] {
            record.count += 1
            Self.scheduling[key] = record
        } else {
            Self.scheduling[key] = SchedulingRecord(preferences: preferences,
                originalPolicy: preferences.inactiveSchedulingPolicy, count: 1)
            preferences.inactiveSchedulingPolicy = .none
        }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                        reason: "Sharing an Oasis window")
    }

    func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        guard var record = Self.scheduling[key] else { return }
        record.count -= 1
        if record.count == 0 {
            record.preferences.inactiveSchedulingPolicy = record.originalPolicy
            Self.scheduling.removeValue(forKey: key)
        } else {
            Self.scheduling[key] = record
        }
    }
}
