import Testing
import BopifyDomain

@Suite("Listening history time ranges")
struct ListeningHistoryTests {
    @Test func legacyProvidersRemainCompatibleWithExplicitRanges() async throws {
        let provider: any ListeningHistoryService = LegacyHistory()
        #expect(try await provider.topItems(.tracks, timeRange: .shortTerm) == [])
        #expect(TopItemTimeRange.shortTerm.rawValue == "short_term")
        #expect(TopItemTimeRange.mediumTerm.rawValue == "medium_term")
        #expect(TopItemTimeRange.longTerm.rawValue == "long_term")
    }
}

private struct LegacyHistory: ListeningHistoryService {
    func recentlyPlayed() async throws -> [RecentPlay] { [] }
    func topItems(_ kind: TopItemKind) async throws -> [StationSeed] { [] }
}
