import Foundation
import Testing
import PelicanCore
@testable import PelicanSentinel

@Suite(.serialized) @MainActor
struct ConnectionTests {
    @Test func keysPreserveOriginalScopeAndIsolateProviderAndEndpoint() throws {
        let openai = try KeychainStore.forProvider(.openai, configuration: .defaults(for: .openai))
        let claude = try KeychainStore.forProvider(.claude, configuration: .defaults(for: .claude))
        let gemini = try KeychainStore.forProvider(.gemini, configuration: .defaults(for: .gemini))
        #expect(Set([openai.service, claude.service, gemini.service]).count == 3)
        #expect(openai.service == "com.pelicansentinel.openai")
        let a = try KeychainStore.forProvider(.compatible, configuration: .init(model: "one", baseURL: "https://EXAMPLE.com/v1/"))
        let same = try KeychainStore.forProvider(.compatible, configuration: .init(model: "two", baseURL: "https://example.com/v1"))
        let otherHost = try KeychainStore.forProvider(.compatible, configuration: .init(model: "one", baseURL: "https://other.example.com/v1"))
        let otherPath = try KeychainStore.forProvider(.compatible, configuration: .init(model: "one", baseURL: "https://example.com/another/v1"))
        #expect(a.service == same.service)
        #expect(a.service != otherHost.service)
        #expect(a.service != otherPath.service)
        #expect(a.service != openai.service)
    }
    @Test func switchingProviderAndModelRestoresOnlyMatchingHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        model.setProvider(.claude)
        #expect(model.saveConfiguration(.init(model: "claude-first")))
        var first = ResultRecord(providerId: .claude, generationMode: .ask, scheduleInterval: 4, status: .success)
        first.requestedModel = "claude-first"
        var second = first; second.id = UUID(); second.requestedModel = "claude-second"
        var foreign = first; foreign.id = UUID(); foreign.providerId = .openai
        model.records = [foreign, second, first]
        #expect(model.recent.map(\.id) == [first.id])
        #expect(model.latest?.id == first.id)
        #expect(model.saveConfiguration(.init(model: "claude-second")))
        #expect(model.recent.map(\.id) == [second.id])
        model.setProvider(.gemini)
        #expect(model.recent.isEmpty)
        #expect(!model.hasAPIKey)
        model.setProvider(.claude)
        #expect(model.configuration.model == "claude-second")
    }
    @Test func invalidDraftKeepsSavedSettingsAndGenerationLocksConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        model.setProvider(.compatible)
        #expect(model.saveConfiguration(.init(model: "local", baseURL: "http://localhost:11434/v1")))
        #expect(model.isConfigured)
        let saved = model.configuration
        #expect(!model.saveConfiguration(.init(model: "changed", baseURL: "http://external.example/v1")))
        #expect(model.configuration == saved)
        #expect(try model.store.settings().selectedConfiguration == saved)
        model.generating = true
        model.setProvider(.openai)
        #expect(model.settings.provider == .compatible)
        #expect(!model.saveConfiguration(.init(model: "changed", baseURL: "https://example.com/v1")))
        #expect(model.configuration == saved)
    }
    @Test func connectionSwitchClearsOldConfirmationAndReschedules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        model.settings.pendingScheduledAt = Date().addingTimeInterval(-60)
        model.settings.nextScheduledAt = Date().addingTimeInterval(-60)
        model.setProvider(.openai)
        #expect(model.settings.pendingScheduledAt == nil)
        #expect(model.settings.nextScheduledAt > Date())
        #expect(try model.store.settings().provider == .openai)
        #expect(AppIdentity.dataDirectoryName == "PelicanSentinel")
    }
}
