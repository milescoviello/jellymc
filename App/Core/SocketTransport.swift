import Foundation

/// A WebSocket that hands text messages to the main actor, and says once when it is gone.
/// Apple's URLSession here; on Linux, a file of the same name speaks libsoup, because
/// Foundation's socket there spins a core while it waits.
@MainActor
final class SocketTransport {
    var onText: (@MainActor (String) -> Void)?
    /// Called once, with why, when the socket closes or could not open. Not after `close()`.
    var onClose: (@MainActor (String) -> Void)?

    private let request: URLRequest
    private var task: URLSessionWebSocketTask?
    private var closed = false

    init(url: URL, authorization: String) {
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        self.request = request
    }

    func open() {
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        Task { await listen(task) }
    }

    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    func close() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func listen(_ task: URLSessionWebSocketTask) async {
        while !closed {
            do {
                switch try await task.receive() {
                case let .string(text): onText?(text)
                case let .data(data): onText?(String(decoding: data, as: UTF8.self))
                @unknown default: continue
                }
            } catch {
                guard !closed else { return }
                closed = true
                onClose?(error.localizedDescription)
                return
            }
        }
    }
}
