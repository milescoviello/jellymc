import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches one file at a time into a staging file, and says how it went.
@MainActor
protocol Downloader: AnyObject {
    var onProgress: (@MainActor (String, Double, Int64?) -> Void)? { get set }
    /// The staged file, which the store moves into place.
    var onFinished: (@MainActor (String, Result<URL, Error>) -> Void)? { get set }
    func start(id: String, url: URL)
    func cancel(id: String)
    /// Downloads the session already has under way: on iOS, ones a background session
    /// carried on with while the app was not running.
    func runningIds() async -> [String]
}

/// URLSession download tasks. On iOS a background session, so a film keeps coming down
/// with the app suspended or the screen locked; the system hands finished files back when
/// the app next runs, under the same session identifier.
@MainActor
final class URLSessionDownloader: NSObject, Downloader {
    var onProgress: (@MainActor (String, Double, Int64?) -> Void)?
    var onFinished: (@MainActor (String, Result<URL, Error>) -> Void)?

    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]

    #if os(iOS)
    /// Handed over when iOS wakes the app for the background session's events; called once
    /// they have all been delivered, so the system can take its snapshot and suspend it.
    static var backgroundCompletion: (() -> Void)?
    #endif

    override init() {
        super.init()
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.milescoviello.jellymc.downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        #else
        let configuration = URLSessionConfiguration.default
        #endif
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 12
        session = URLSession(configuration: configuration, delegate: Relay(self), delegateQueue: nil)
    }

    func start(id: String, url: URL) {
        let task = session.downloadTask(with: url)
        task.taskDescription = id
        tasks[id] = task
        task.resume()
    }

    func cancel(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    func runningIds() async -> [String] {
        let running = await session.allTasks.compactMap { task -> (String, URLSessionDownloadTask)? in
            guard let task = task as? URLSessionDownloadTask, task.state == .running || task.state == .suspended,
                  let id = task.taskDescription else { return nil }
            return (id, task)
        }
        for (id, task) in running { tasks[id] = task }
        return running.map(\.0)
    }

    fileprivate func progressed(_ id: String, written: Int64, expected: Int64) {
        let fraction = expected > 0 ? Double(written) / Double(expected) : 0
        onProgress?(id, fraction, written)
    }

    fileprivate func finished(_ id: String, _ result: Result<URL, Error>) {
        tasks[id] = nil
        onFinished?(id, result)
    }

    /// The session's delegate: called on URLSession's own queue, so it hops to the main
    /// actor, after moving the file — the system deletes it once the callback returns.
    private final class Relay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        weak var owner: URLSessionDownloader?

        init(_ owner: URLSessionDownloader) {
            self.owner = owner
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let id = downloadTask.taskDescription else { return }
            Task { @MainActor [weak owner] in owner?.progressed(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let id = downloadTask.taskDescription else { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<URL, Error>
            if (200 ..< 300).contains(status) {
                let staged = FileManager.default.temporaryDirectory.appendingPathComponent("jellymc-\(id)-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: location, to: staged)
                    result = .success(staged)
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(JellyfinError(kind: .http(status), message: "The server answered \(status) to the download."))
            }
            Task { @MainActor [weak owner] in owner?.finished(id, result) }
        }

        #if os(iOS)
        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor in
                URLSessionDownloader.backgroundCompletion?()
                URLSessionDownloader.backgroundCompletion = nil
            }
        }
        #endif

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let id = task.taskDescription else { return }
            if (error as NSError).code == NSURLErrorCancelled { return }
            let message = error.localizedDescription
            Task { @MainActor [weak owner] in
                owner?.finished(id, .failure(JellyfinError(kind: .transport, message: message)))
            }
        }
    }
}
