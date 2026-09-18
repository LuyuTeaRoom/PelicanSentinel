import Foundation
import Testing
@testable import PelicanCore

private actor CountingProvider: ModelProvider {
    var calls = 0
    let content: String
    init(_ content: String) { self.content = content }
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        calls += 1
        #expect(request.prompt == Benchmark.prompt)
        return ProviderResponse(rawResponse: "RAW\n" + content, content: content, returnedModel: "test-model", executionProfile: "fixture")
    }
    func count() -> Int { calls }
}
private struct CancelProvider: ModelProvider {
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse { throw CancellationError() }
}
private struct SlowProvider: ModelProvider {
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        try await Task.sleep(nanoseconds: 100_000_000)
        return ProviderResponse(rawResponse: "", content: "", executionProfile: "fixture")
    }
}
@Suite(.serialized)
final class StoreServiceTests {
    private var roots: [URL] = []
    deinit { for root in roots { try? FileManager.default.removeItem(at: root) } }
    func makeStore() throws -> ResultStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return try ResultStore(root: root)
    }
    @Test func testSettingsRoundTripNoSecretAndTraversal() throws {
        let store = try makeStore()
        var settings = AppSettings(); settings.intervalHours = 2; settings.pendingScheduledAt = Date(timeIntervalSince1970: 1000)
        try store.saveSettings(settings)
        #expect(try store.settings().intervalHours == 2)
        #expect(try store.settings().pendingScheduledAt == settings.pendingScheduledAt)
        #expect(store.url(for: "../../outside") == nil)
        let json = try String(contentsOf: store.root.appendingPathComponent("settings.json"))
        #expect(!(json.lowercased().contains("api_key")))
    }
    @Test func testRetentionRemovesAssociatedFilesOnly() throws {
        let store = try makeStore(); let now = Date()
        var old = ResultRecord(providerId: .codex, completedAt: now.addingTimeInterval(-31 * 86400), generationMode: .ask, scheduleInterval: 4, status: .success)
        old.rawResponsePath = try store.saveText("raw", id: old.id, suffix: "response.txt")
        old.svgPath = try store.saveText("svg", id: old.id, suffix: "svg")
        try store.save(old)
        let new = ResultRecord(providerId: .codex, generationMode: .ask, scheduleInterval: 4, status: .success); try store.save(new)
        try store.prune(now: now)
        #expect(try store.records().map(\.id) == [new.id])
        #expect(!(FileManager.default.fileExists(atPath: store.url(for: old.svgPath!)!.path)))
    }
    @Test @MainActor func testSuccessThenInvalidKeepsSuccessAndNeverRendersUnsafe() async throws {
        let store = try makeStore(); let service = GenerationService(store: store)
        let good = CountingProvider("<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"5\"/></svg>")
        let first = try await service.generate(provider: good, settings: .init())
        #expect(first.status == .success)
        let malicious = CountingProvider("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>")
        var rendered = false
        let bad = try await service.generate(provider: malicious, settings: .init(), thumbnail: { _ in rendered = true; return Data() })
        #expect(bad.status == .blockedSVG); #expect(!(rendered))
        #expect(bad.svgPath != nil); #expect(bad.rawResponsePath != nil)
        let raw = try String(contentsOf: store.url(for: bad.rawResponsePath!)!)
        #expect(raw.contains("<script>"))
        let count = await malicious.count(); #expect(count == 1)
        #expect(try store.records().first { $0.status == .success }?.id == first.id)
        #expect(first.promptHash == Benchmark.promptHash); #expect(first.returnedModel == "test-model")
    }
    @Test @MainActor func testEmptyCancelledAndSkipAreIndependentRecords() async throws {
        let store = try makeStore(); let service = GenerationService(store: store)
        let empty = try await service.generate(provider: CountingProvider(" "), settings: .init())
        #expect(empty.status == .emptyResponse)
        let cancelled = try await service.generate(provider: CancelProvider(), settings: .init())
        #expect(cancelled.status == .cancelled)
        let due = Date(timeIntervalSince1970: 500)
        let skipped = try service.skip(settings: .init(), scheduledAt: due)
        #expect(skipped.status == .skippedByUser); #expect(skipped.scheduledAt == due)
        #expect(try store.records().count == 3)
    }
    @Test @MainActor func testConcurrentGenerationDoesNotStartSecondRequest() async throws {
        let service = GenerationService(store: try makeStore())
        let task = Task { try await service.generate(provider: SlowProvider(), settings: .init()) }
        await Task.yield()
        do { _ = try await service.generate(provider: SlowProvider(), settings: .init()); Issue.record("must reject concurrent generation") }
        catch let error as ProviderFailure { #expect(error.type == "busy") }
        _ = try await task.value
    }
    @Test func testDifferentProviderSeriesAreDistinct() {
        let codex = ResultRecord(providerId: .codex, generationMode: .ask, scheduleInterval: 4, status: .success)
        let api = ResultRecord(providerId: .openai, generationMode: .ask, scheduleInterval: 4, status: .success)
        #expect(codex.seriesID != api.seriesID)
    }
    @Test func testCorruptRecordIsReportedWithoutBlockingValidHistoryOrPruning() throws {
        let store = try makeStore()
        let good = ResultRecord(providerId: .codex, generationMode: .ask, scheduleInterval: 4, status: .success)
        try store.save(good)
        let broken = store.root.appendingPathComponent("results/broken.json")
        let original = Data("{broken".utf8); try original.write(to: broken)
        let history = try store.history()
        #expect(history.records.map(\.id) == [good.id])
        #expect(history.unreadableFiles == ["broken.json"])
        try store.prune()
        #expect(try Data(contentsOf: broken) == original)
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("results"))
        #expect(throws: (any Error).self) { try store.history() }
    }
    @Test @MainActor func testAttemptIsSavedBeforeProviderAndCancellationUpdatesSameID() async throws {
        let store = try makeStore(), provider = SlowProvider()
        let service = GenerationService(store: store)
        let task = Task { try await service.generate(provider: provider, settings: .init()) }
        while !service.isGenerating { await Task.yield() }
        let saved = try #require(store.records().first)
        #expect(saved.status == .generating)
        #expect(saved.completedAt == nil)
        task.cancel()
        let result = try await task.value
        #expect(result.id == saved.id)
        #expect(result.status == .cancelled)
        #expect(try store.records().count == 1)
    }
    @Test @MainActor func testFailedPlanCommitNeverCallsProvider() async throws {
        let store = try makeStore(), provider = CountingProvider("<svg><circle r=\"5\"/></svg>")
        let service = GenerationService(store: store)
        let result = try await service.generate(provider: provider, settings: .init(), beforeRequest: { throw CocoaError(.fileWriteNoPermission) })
        #expect(await provider.count() == 0)
        #expect(result.status == .storageError)
        #expect(try store.records().count == 1)
    }
    @Test @MainActor func testRecoveryAcrossPlanCommitBoundariesNeverResends() async throws {
        for advanced in [false, true] {
            let store = try makeStore(), now = Date(timeIntervalSince1970: 100_000)
            let due = now.addingTimeInterval(-60)
            var settings = AppSettings(); settings.mode = .automatic
            settings.nextScheduledAt = advanced ? due.addingTimeInterval(14_400) : due
            settings.pendingScheduledAt = due
            try store.saveSettings(settings)
            let attempt = ResultRecord(providerId: .codex, scheduledAt: due, completedAt: nil, generationMode: .automatic, scheduleInterval: 4, status: .generating)
            try store.save(attempt)
            try store.recoverInterrupted(now: now)
            let recovered = try store.reconciledSettings(store.settings(), now: now)
            #expect(recovered.pendingScheduledAt == nil)
            #expect(recovered.nextScheduledAt == due.addingTimeInterval(14_400))
            let provider = CountingProvider("<svg><circle r=\"5\"/></svg>")
            let duplicate = try await GenerationService(store: store).generate(provider: provider, settings: recovered, scheduledAt: due)
            #expect(await provider.count() == 0)
            #expect(duplicate.id == attempt.id)
            #expect(duplicate.status == .interrupted)
            #expect(try store.records().count == 1)
        }
    }
    @Test @MainActor func testInitialSaveFailureDoesNotSendRequest() async throws {
        let store = try makeStore(), provider = CountingProvider("<svg><circle/></svg>")
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("results"))
        do { _ = try await GenerationService(store: store).generate(provider: provider, settings: .init()); Issue.record("Save must fail") }
        catch { }
        #expect(await provider.count() == 0)
    }
    @Test @MainActor func testSVGWriteFailureIsStorageErrorNotModelFailure() async throws {
        let store = try makeStore()
        let result = try await GenerationService(store: store).generate(provider: BlockSVGWrite(root: store.root), settings: .init())
        #expect(result.status == .storageError)
        #expect(result.rawResponsePath != nil)
        #expect(result.errorType == "storage_error")
    }
    @Test @MainActor func testFailureMetadataAndExecutionProfileSurvive() async throws {
        let store = try makeStore()
        let result = try await GenerationService(store: store).generate(provider: MetadataFailure(), settings: .init())
        #expect(result.status == .outputTruncated)
        #expect(result.returnedModel == "known-model")
        #expect(result.usage.totalTokens == 16394)
        #expect(result.executionProfile == "known-profile")
    }
    @Test func testLegacyHistoryReadsWithoutRewritingAndConfigurationLabelsAreHonest() throws {
        let store = try makeStore()
        var old = ResultRecord(providerId: .codex, generationMode: .ask, scheduleInterval: 4, status: .success)
        old.executionProfile = "codex-cli;legacy"
        try store.save(old)
        let file = store.root.appendingPathComponent("results/\(old.id.uuidString).json")
        let original = try Data(contentsOf: file)
        let read = try #require(store.records().first)
        #expect(read.completedAt != nil)
        #expect(!read.configurationKnown)
        #expect(read.configurationNote(comparedTo: nil) == "Configuration not fully recorded")
        #expect(try Data(contentsOf: file) == original)
        var current = old; current.executionProfile = "codex-cli;cli-version=1.0"
        var next = current; next.executionProfile = "codex-cli;cli-version=1.1"
        #expect(next.configurationNote(comparedTo: current) == "Generation settings changed")
        #expect(next.configurationNote(comparedTo: old) == nil)
        next.status = .skippedByUser
        #expect(next.configurationNote(comparedTo: current) == nil)
    }

}

private struct BlockSVGWrite: ModelProvider {
    let root: URL
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        let store = try ResultStore(root: root)
        let id = try #require(store.records().first?.id)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("results/\(id.uuidString).svg"), withIntermediateDirectories: false)
        return .init(rawResponse: "original", content: "<svg><circle r=\"5\"/></svg>", executionProfile: "fixture")
    }
}
private struct MetadataFailure: ModelProvider {
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        throw ProviderFailure(type: "output_truncated", message: "截断", rawResponse: "original", status: .outputTruncated, returnedModel: "known-model", usage: .init(totalTokens: 16394), executionProfile: "known-profile")
    }
}
