import Foundation
import Testing

@testable import JellyCore

/// Against a real server: `tools/testserver/up.sh`, then
/// `JELLYMC_TEST_SERVER=http://localhost:8096 tools/swiftw test`.
///
/// What these pin down is the server's own decision for each player's profile — the part
/// no fixture can stand in for, and the part a 12.x point release could change.
// Serialized: signing in again with the same DeviceId revokes the previous token, so
// these must not sign in in parallel.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JELLYMC_TEST_SERVER"] != nil))
struct LiveServerTests {
    private static let device = DeviceIdentity(deviceName: "tests", deviceId: "jellymc-tests", version: "0")

    private func signIn() async throws -> JellyfinClient {
        let url = try #require(URL(string: ProcessInfo.processInfo.environment["JELLYMC_TEST_SERVER"] ?? ""))
        let anonymous = JellyfinClient(baseURL: url, device: Self.device)
        _ = try await anonymous.publicInfo()
        let result = try await anonymous.authenticate(username: "jellymc", password: "jellymc")
        return anonymous.signedIn(token: result.accessToken, userId: result.user.id)
    }

    private func movie(_ name: String, _ client: JellyfinClient) async throws -> BaseItem {
        var query = ItemQuery()
        query.recursive = true
        query.includeItemTypes = [.movie]
        query.searchTerm = name
        query.fields = JellyfinClient.detailFields
        return try #require(try await client.items(query).items.first { $0.name == name })
    }

    private func plan(_ item: BaseItem, _ player: PlayerKind, _ client: JellyfinClient, subtitle: Int? = -1) async throws -> PlaybackPlan {
        let request = PlaybackInfoRequest(
            userId: client.userId, maxStreamingBitrate: 120_000_000, startTimeTicks: 0,
            audioStreamIndex: nil, subtitleStreamIndex: subtitle, mediaSourceId: item.mediaSources?.first?.id ?? item.id,
            deviceProfile: DeviceProfiles.profile(for: player)
        )
        let response = try await client.playbackInfo(itemId: item.id, request: request)
        return try PlaybackPlan.make(itemId: item.id, response: response, startSeconds: 0, audioIndex: nil, subtitleIndex: nil, client: client)
    }

    @Test func mpvPlaysEveryFilmAsItIs() async throws {
        let client = try await signIn()
        for name in ["Big Buck Bunny", "Sintel", "Elephants Dream", "Tears of Steel"] {
            let item = try await movie(name, client)
            let plan = try await plan(item, .mpv, client)
            #expect(plan.method == .directPlay, "\(name): \(plan.method) \(plan.transcodeReasons)")
        }
    }

    @Test func avPlayerDirectPlaysMP4AndRemuxesMKV() async throws {
        let client = try await signIn()
        let bunny = try await plan(try await movie("Big Buck Bunny", client), .avPlayer, client)
        #expect(bunny.method == .directPlay)

        // H.264 and AC-3 in Matroska: only the container is wrong, so the server remuxes —
        // though it marks the source SupportsDirectStream: false and calls it a transcode.
        let elephants = try await plan(try await movie("Elephants Dream", client), .avPlayer, client)
        #expect(elephants.method != .directPlay)
        #expect(elephants.videoIsCopied, "\(elephants.transcodeReasons)")
        #expect(elephants.methodTitle == "Remux")
        #expect(elephants.url.absoluteString.contains(".m3u8"))
        #expect(elephants.url.absoluteString.contains("ApiKey="))
    }

    @Test func avPlayerBurnsInStyledASS() async throws {
        let client = try await signIn()
        let sintel = try await movie("Sintel", client)
        let ass = try #require(sintel.mediaSources?.first?.subtitleStreams.first { $0.codec == "ass" })
        let plan = try await plan(sintel, .avPlayer, client, subtitle: ass.index)
        #expect(plan.method == .transcode)
        #expect(!plan.videoIsCopied)
        #expect(plan.url.absoluteString.contains("SubtitleStreamIndex=\(ass.index)"), "\(plan.url)")
        #expect(plan.url.absoluteString.contains("SubtitleMethod=Encode"), "\(plan.url)")
    }

    @Test func theServerTakesOurReports() async throws {
        let client = try await signIn()
        let item = try await movie("Big Buck Bunny", client)
        let plan = try await plan(item, .mpv, client)
        let report = PlaybackReport(plan: plan, position: 30, isPaused: false)
        try await client.sendNoContent("POST", "Sessions/Playing", body: report)
        try await client.sendNoContent("POST", "Sessions/Playing/Progress", body: report)
        try await client.sendNoContent("POST", "Sessions/Playing/Stopped", body: report)
        let after = try await client.item(item.id)
        #expect(after.userData?.playbackPositionTicks == 300_000_000)
        _ = try await client.setPlayed(false, itemId: item.id)
        try await client.setPosition(0, played: false, lastPlayed: Date(), itemId: item.id)
    }

    @Test func homeRowsAndSegments() async throws {
        let client = try await signIn()
        let views = try await client.userViews()
        #expect(views.count == 3)
        for view in views {
            _ = try await client.latest(parentId: view.id)
        }
        _ = try await client.nextUp()
        _ = try await client.resume()
        let item = try await movie("Sintel", client)
        let segments = try await client.mediaSegments(itemId: item.id)
        #expect(segments.isEmpty)
    }
}
