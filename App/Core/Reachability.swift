import Foundation
import Network
import Observation

/// Whether there is a network, and whether it costs. On Linux the same type is GIO's
/// network monitor (`Linux/Sources/JellyCore/Platform/Reachability.swift`).
@MainActor
@Observable
final class Reachability {
    private(set) var isOnline = true
    private(set) var isExpensive = false
    private(set) var isConstrained = false

    var network: NetworkKind {
        guard isOnline else { return .offline }
        return isExpensive || isConstrained ? .cellular : .wifi
    }

    @ObservationIgnored var onCameOnline: (() -> Void)?
    @ObservationIgnored var onNetworkChange: (() -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in self?.update(online: online, expensive: expensive, constrained: constrained) }
        }
        monitor.start(queue: DispatchQueue(label: "jellymc.reachability"))
    }

    private func update(online: Bool, expensive: Bool, constrained: Bool) {
        let wasOnline = isOnline
        let previous = network
        isOnline = online
        isExpensive = expensive
        isConstrained = constrained
        if isOnline, !wasOnline { onCameOnline?() }
        if network != previous { onNetworkChange?() }
    }
}
