import AppKit
import Darwin
import Foundation

@MainActor
enum ScreenRecordingDetector {
    private static var lastCheckTime: CFAbsoluteTime = 0
    private static var cachedSystemRecording: Bool = false
    private static let cacheDuration: CFAbsoluteTime = 0.5

    /// Manual override if desired (e.g. via menu item or testing).
    static var manualOverride: Bool? = nil

    /// Returns true if tab sharing in Oasis is active or any system screen recording is active.
    static func isRecordingActive(for tab: BrowserTab?) -> Bool {
        if let manual = manualOverride { return manual }
        if let tab, tab.isSharing { return true }
        if let session = tab?.session, session.tabs.contains(where: { $0.isSharing }) { return true }
        return isSystemRecordingActive
    }

    /// Checks whether system-level screen recording is currently active.
    static var isSystemRecordingActive: Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastCheckTime < cacheDuration {
            return cachedSystemRecording
        }
        lastCheckTime = now
        cachedSystemRecording = checkSystemRecording()
        return cachedSystemRecording
    }

    private static func checkSystemRecording() -> Bool {
        // 1. macOS native screen recording (Cmd+Shift+5 / screencapture CLI)
        if isProcessRunning(named: "screencapture") { return true }

        // 2. QuickTime Player active screen recording
        if isQuickTimeRecording() { return true }

        // 3. Check for active OBS Studio app running
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.obsproject.obs-studio").isEmpty {
            return true
        }

        return false
    }

    private static func isProcessRunning(named targetName: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 2048)
        let bytesUsed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard bytesUsed > 0 else { return false }
        let count = Int(bytesUsed) / MemoryLayout<pid_t>.stride
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            if len > 0 {
                let path = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if path.hasSuffix("/" + targetName) || path == targetName {
                    return true
                }
            }
        }
        return false
    }

    private static func isQuickTimeRecording() -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.QuickTimePlayerX").isEmpty else { return false }
        let script = """
        tell application id "com.apple.QuickTimePlayerX"
            repeat with doc in documents
                if name of doc is "Screen Recording" and current time of doc > 0.0 then return true
            end repeat
        end tell
        return false
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            return appleScript.executeAndReturnError(&error).booleanValue
        }
        return false
    }
}
