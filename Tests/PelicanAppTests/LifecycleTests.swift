import Foundation
import Testing
import PelicanCore
@testable import PelicanSentinel

private actor AppProbe: ModelProvider {
    var calls = 0
    let delay: UInt64
    init(delay: UInt64 = 20_000_000) { self.delay = delay }
    func executionProfile(for request: GenerationRequest) async -> String? { "fixture;cli-version=1" }
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        calls += 1
        try await Task.sleep(nanoseconds: delay)
        return .init(rawResponse: "fixture", content: "", executionProfile: "fixture;cli-version=1")
    }
    func count() -> Int { calls }
}
@Suite(.serialized) @MainActor
struct LifecycleTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pelican-app-test-\(UUID().uuidString)") }
    private func finished(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if !model.generating { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Generation did not finish within test deadline")
    }
    @Test func startupRecoversBeforeSchedulingAndPreservesBadRecord() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try ResultStore(root: root)
        let due = Date().addingTimeInterval(-60)
        var settings = AppSettings(); settings.nextScheduledAt = due; settings.pendingScheduledAt = due
        try store.saveSettings(settings)
        let interrupted = ResultRecord(providerId: .codex, scheduledAt: due, completedAt: nil, generationMode: .ask, scheduleInterval: 4, status: .generating)
        try store.save(interrupted)
        let broken = root.appendingPathComponent("results/broken.json"); try Data("{".utf8).write(to: broken)
        let model = try AppModel(root: root, testing: true)
        #expect(model.records.first?.status == .interrupted)
        #expect(model.settings.pendingScheduledAt == nil)
        #expect(model.settings.nextScheduledAt > Date())
        #expect(model.unreadableHistory == ["broken.json"])
        #expect(FileManager.default.fileExists(atPath: broken.path))
    }
    @Test func automaticWakeSendsAtMostOnceAndPersistsNextPlan() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true), probe = AppProbe()
        let now = Date(); model.settings.mode = .automatic
        model.settings.nextScheduledAt = now.addingTimeInterval(-8 * 3600)
        try model.store.saveSettings(model.settings)
        model.tick(now: now, providerOverride: probe)
        model.tick(now: now, providerOverride: probe)
        try await finished(model)
        model.tick(now: now, providerOverride: probe)
        #expect(await probe.count() == 1)
        #expect(model.records.count == 1)
        #expect(try model.store.settings().nextScheduledAt > now)
    }
    @Test func askNeedsExplicitChoiceAndSkipSurvivesRestart() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true), probe = AppProbe()
        let now = Date(); model.settings.nextScheduledAt = now.addingTimeInterval(-10)
        model.tick(now: now, providerOverride: probe)
        model.tick(now: now, providerOverride: probe)
        #expect(await probe.count() == 0)
        #expect(model.settings.pendingScheduledAt != nil)
        model.skip()
        let reopened = try AppModel(root: root, testing: true)
        #expect(reopened.settings.pendingScheduledAt == nil)
        #expect(reopened.records.first?.status == .skippedByUser)
    }
    @Test func quitCancelsOwnedTaskAndKeepsAttempt() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true), probe = AppProbe(delay: 10_000_000_000)
        model.generate(providerOverride: probe)
        for _ in 0..<100 {
            if await probe.count() == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await model.prepareForTermination()
        #expect(!model.generating)
        #expect(model.shuttingDown)
        #expect(try model.store.records().first?.status == .cancelled)
        model.generate(providerOverride: probe)
        #expect(await probe.count() == 1)
    }
    @Test func historyShowsConfigurationChangesWithoutHidingFailures() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        model.setLanguage(.english)
        var older = ResultRecord(providerId: .codex, startedAt: Date(timeIntervalSince1970: 10), generationMode: .ask, scheduleInterval: 4, status: .success)
        older.executionProfile = "fixture;cli-version=1"
        older.requestConfiguration = model.configuration
        var newer = ResultRecord(providerId: .codex, startedAt: Date(timeIntervalSince1970: 20), generationMode: .ask, scheduleInterval: 4, status: .apiError)
        newer.executionProfile = "fixture;cli-version=2"
        model.records = [newer, older]
        #expect(model.recent.count == 2)
        #expect(model.configurationNote(for: newer) == "Generation settings changed")
        #expect(model.latest?.id == older.id)
        #expect(model.latestConfigurationNote == "Last image uses different settings.")
        newer.executionProfile = older.executionProfile
        newer.returnedModel = "snapshot-new"; older.returnedModel = "snapshot-old"
        model.records = [newer, older]
        #expect(model.configurationNote(for: newer) == "Returned model changed")
        #expect(model.latestConfigurationNote == "Last image came from a different returned model.")
    }
}
