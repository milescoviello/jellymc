import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the server pushes over its WebSocket, as far as the app acts on it. Shapes from the
/// 12.2 OpenAPI spec's `OutboundWebSocketMessage` family.
enum ServerMessage: Sendable, Equatable {
    /// The server drops a socket that is quiet for this many seconds.
    case forceKeepAlive(seconds: Int)
    /// Watched marks, places or favourites changed: from this device or another.
    case userDataChanged([UserDataChange])
    /// Items were added, removed or changed.
    case libraryChanged
    /// Another device asks this one to play something.
    case play(RemotePlay)
    case playstate(RemotePlaystate)
    case command(RemoteCommand)
    case other(String)

    static func decode(_ data: Data) -> ServerMessage? {
        let decoder = JSONCoding.decoder()
        guard let type = try? decoder.decode(Kind.self, from: data).messageType else { return nil }
        func payload<T: Decodable>(_: T.Type) -> T? { (try? decoder.decode(Envelope<T>.self, from: data))?.data }
        switch type {
        case "ForceKeepAlive": return payload(Int.self).map { .forceKeepAlive(seconds: $0) }
        case "UserDataChanged": return .userDataChanged(payload(UserDataChangeInfo.self)?.userDataList ?? [])
        case "LibraryChanged": return .libraryChanged
        case "Play": return payload(RemotePlay.self).map(ServerMessage.play)
        case "Playstate": return payload(RemotePlaystate.self).map(ServerMessage.playstate)
        case "GeneralCommand": return payload(RemoteCommand.self).map(ServerMessage.command)
        default: return .other(type)
        }
    }

    private struct Envelope<T: Decodable>: Decodable {
        var messageType: String
        var data: T?
    }

    private struct Kind: Decodable {
        var messageType: String
    }

    private struct UserDataChangeInfo: Decodable {
        var userDataList: [UserDataChange]?
    }
}

/// One item's user data, as the server says it is now.
struct UserDataChange: Codable, Sendable, Equatable {
    var itemId: String
    var playbackPositionTicks: Int64?
    var played: Bool?
    var isFavorite: Bool?
}

struct RemotePlay: Codable, Sendable, Equatable {
    var itemIds: [String]?
    var startPositionTicks: Int64?
    /// PlayNow, PlayNext, PlayLast, PlayInstantMix, PlayShuffle.
    var playCommand: String?
    var mediaSourceId: String?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var startIndex: Int?

    /// The one item this app plays: it keeps no queue.
    var itemId: String? {
        guard let ids = itemIds, !ids.isEmpty else { return nil }
        return ids[min(max(startIndex ?? 0, 0), ids.count - 1)]
    }

    var start: Double? { startPositionTicks.map(Ticks.seconds) }
}

struct RemotePlaystate: Codable, Sendable, Equatable {
    /// Stop, Pause, Unpause, NextTrack, PreviousTrack, Seek, Rewind, FastForward, PlayPause.
    var command: String
    var seekPositionTicks: Int64?
}

struct RemoteCommand: Codable, Sendable, Equatable {
    var name: String
    var arguments: [String: String]?

    /// The decoder's key strategy reaches dictionary keys too ("Index" comes out "index"),
    /// so arguments are looked up regardless of case.
    func argument(_ key: String) -> String? {
        arguments?.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

/// The server's WebSocket: user data changes, library changes and remote control come in;
/// a keep-alive goes out. Reopens itself when it drops, until it is told to stop.
@MainActor
final class Realtime {
    var onMessage: (@MainActor (ServerMessage) -> Void)?
    private(set) var isConnected = false

    private var client: JellyfinClient?
    private var socket: SocketTransport?
    /// Bumped by every open and close, so a socket's late callbacks are told apart.
    private var generation = 0
    private var keepAlive: Task<Void, Never>?
    private var reopen: Task<Void, Never>?
    private var delay: Double = 5

    func connect(_ client: JellyfinClient) {
        close()
        self.client = client
        delay = 5
        open()
    }

    func disconnect() {
        client = nil
        close()
    }

    private func open() {
        guard let client, let url = client.socketURL else { return }
        generation += 1
        let generation = generation
        let socket = SocketTransport(url: url, authorization: client.authorization)
        self.socket = socket
        socket.onText = { [weak self] text in
            guard let self, generation == self.generation else { return }
            self.received(text)
        }
        socket.onClose = { [weak self] reason in
            guard let self, generation == self.generation else { return }
            self.dropped(reason)
        }
        socket.open()
    }

    private func received(_ text: String) {
        if !isConnected {
            isConnected = true
            delay = 5
            Task { await Diagnostics.shared.record("realtime", "socket open") }
        }
        guard let parsed = ServerMessage.decode(Data(text.utf8)) else { return }
        if case let .forceKeepAlive(seconds) = parsed { startKeepAlive(every: max(5, Double(seconds) / 2)) }
        onMessage?(parsed)
    }

    private func dropped(_ reason: String) {
        socket = nil
        isConnected = false
        keepAlive?.cancel()
        let wait = delay
        Task { await Diagnostics.shared.record("realtime", "socket closed (\(reason)); again in \(Int(wait)) s") }
        scheduleReopen()
    }

    private func startKeepAlive(every seconds: Double) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let socket = self?.socket else { return }
                socket.send(#"{"MessageType":"KeepAlive"}"#)
            }
        }
    }

    private func scheduleReopen() {
        let wait = delay
        delay = min(delay * 2, 120)
        reopen = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, self.client != nil else { return }
            self.open()
        }
    }

    private func close() {
        generation += 1
        isConnected = false
        keepAlive?.cancel()
        reopen?.cancel()
        socket?.close()
        socket = nil
    }
}
