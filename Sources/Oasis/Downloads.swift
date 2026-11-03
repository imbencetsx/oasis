import SwiftUI
import WebKit
import CefKit

@MainActor @Observable
final class DownloadItem: Identifiable {
    let id = UUID()
    var name = "Preparing download…"
    var destination: URL?
    var fraction = 0.0
    var status = "Waiting for a destination"
    var isFinished = false
    var failed = false
    @ObservationIgnored var chromiumID: UInt32?
    @ObservationIgnored var chromiumCancel: (() -> Void)?
    @ObservationIgnored var download: WKDownload?
    @ObservationIgnored var observation: NSKeyValueObservation?
}

@MainActor @Observable
final class BrowserDownloads: NSObject, WKDownloadDelegate {
    static let shared = BrowserDownloads()
    var items: [DownloadItem] = []
    var activeCount: Int { items.filter { !$0.isFinished }.count }

    func receiveChromium(_ download: CefDownload, suggestedName: String) -> CefDownloadDecision {
        let panel = NSSavePanel()
        panel.title = "Save Download"
        panel.nameFieldStringValue = (suggestedName as NSString).lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return .deny }
        let item = DownloadItem()
        item.chromiumID = download.id; item.name = panel.nameFieldStringValue
        item.destination = destination; item.status = "Downloading"
        items.insert(item, at: 0)
        return .allow(destination: destination)
    }
    func updateChromium(_ download: CefDownload) {
        guard let item = items.first(where: { $0.chromiumID == download.id }) else { return }
        item.destination = download.fullPath ?? item.destination
        item.fraction = download.totalBytes > 0 ? Double(download.receivedBytes) / Double(download.totalBytes) : 0
        item.isFinished = download.isComplete || download.isCanceled
        if download.isComplete { item.status = "Complete"; item.fraction = 1 }
        else if download.isCanceled { item.status = "Cancelled"; item.failed = true }
    }
    func receive(_ download: WKDownload) {
        let item = DownloadItem()
        item.download = download
        items.insert(item, at: 0)
        download.delegate = self
        item.observation = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak item] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in item?.fraction = fraction }
        }
    }
    private func item(for download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let item = item(for: download) else { completionHandler(nil); return }
        item.name = suggestedFilename
        let panel = NSSavePanel()
        panel.title = "Save Download"
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { result in
            guard result == .OK, let destination = panel.url else {
                item.status = "Cancelled"; item.isFinished = true
                completionHandler(nil)
                return
            }
            item.destination = destination
            item.status = "Downloading"
            completionHandler(destination)
        }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.status = "Complete"; item.fraction = 1; item.isFinished = true
        item.observation = nil; item.download = nil
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.status = (error as NSError).code == NSURLErrorCancelled ? "Cancelled" : error.localizedDescription
        item.isFinished = true; item.failed = true; item.observation = nil; item.download = nil
    }
    func cancel(_ item: DownloadItem) {
        item.chromiumCancel?()
        item.download?.cancel { _ in }
        item.status = "Cancelled"; item.isFinished = true; item.download = nil; item.observation = nil
    }
    func cancelAll() { for item in items where !item.isFinished { cancel(item) } }
    func clearFinished() { items.removeAll { $0.isFinished } }
}
