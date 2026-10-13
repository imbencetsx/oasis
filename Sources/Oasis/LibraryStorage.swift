import Foundation

/// Serialize snapshots and atomic writes away from the UI thread. The same
/// queue orders normal saves and the synchronous final save used on app exit.
final class LibraryStorage: Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "Oasis library storage", qos: .utility)

    init(url: URL) { self.url = url }

    func schedule(_ snapshot: LibraryData, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [url] in
            completion(Result { try Self.write(snapshot, to: url) })
        }
    }

    func flush(_ snapshot: LibraryData) throws {
        try queue.sync { try Self.write(snapshot, to: url) }
    }

    private static func write(_ snapshot: LibraryData, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
