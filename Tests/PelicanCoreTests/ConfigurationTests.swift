import Foundation
import Testing
@testable import PelicanCore

private actor RequestCapture: ModelProvider {
    var received: [GenerationRequest] = []
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        received.append(request)
        return .init(rawResponse: "fixture", content: "<svg><circle r=\"5\"/></svg>", returnedModel: "server-snapshot", executionProfile: "fixture;cli-version=1")
    }
    func requests() -> [GenerationRequest] { received }
}

@Suite(.serialized)
struct ConfigurationTests {
    @Test func legacySettingsKeepScheduleAndDefaults() throws {
        let date = "2026-09-17T12:00:00Z"
        let data = Data("""
        {"provider":"openai","intervalHours":2,"mode":"ask","nextScheduledAt":"\(date)","pendingScheduledAt":"\(date)","retentionDays":30,"codexExecutable":"/some/codex"}
        """.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(AppSettings.self, from: data)
        #expect(settings.provider == .openai)
        #expect(settings.intervalHours == 2)
        #expect(settings.pendingScheduledAt == settings.nextScheduledAt)
        #expect(settings.selectedConfiguration.model == Benchmark.model)
        #expect(settings.selectedConfiguration.reasoning == Benchmark.reasoning)
        #expect(settings.codexExecutable == "/some/codex")
        #expect(settings.language == .chinese)
        #expect(settings.imageSavePath == nil)
    }
    @Test func configurationsPersistSeparatelyAndWithoutSecrets() throws {
        var settings = AppSettings()
        settings.language = .english
        settings.imageSavePath = "/some/自选图片"
        settings.providerConfigurations["openai"] = .init(model: "gpt-custom", reasoning: "default")
        settings.providerConfigurations["claude"] = .init(model: "claude-custom", outputLimit: 2048)
        settings.providerConfigurations["compatible"] = .init(model: "local-model", baseURL: "http://localhost:11434/v1", tokenLimitField: .maxCompletionTokens)
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(restored.language == .english)
        #expect(restored.imageSavePath == "/some/自选图片")
        #expect(restored.configuration(for: .openai).model == "gpt-custom")
        #expect(restored.configuration(for: .claude).outputLimit == 2048)
        #expect(restored.configuration(for: .compatible).tokenLimitField == .maxCompletionTokens)
        #expect(restored.configuration(for: .gemini).model == ProviderID.gemini.descriptor.defaultModel)
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("api_key"))
    }
    @Test func endpointValidationPreservesExplicitServiceBoundary() throws {
        #expect(try CompatibleEndpoint.normalizedBaseURL(" HTTPS://EXAMPLE.COM/v1/ ") == "https://example.com/v1")
        #expect(try CompatibleEndpoint.completionURL("http://127.0.0.1:11434/v1").absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
        #expect(try CompatibleEndpoint.normalizedBaseURL("http://[::1]:8080/v1") == "http://[::1]:8080/v1")
        for invalid in ["", "file:///tmp", "http://example.com/v1", "https://key@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment", "https://example.com/v1/chat/completions", "https://example.com/v1/responses", "https://example.com:99999/v1", "http://localhost.example.com/v1"] {
            #expect(throws: ProviderFailure.self) { try CompatibleEndpoint.normalizedBaseURL(invalid) }
        }
    }
    @Test @MainActor func selectedModelAndControlsReachRequestAndRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ResultStore(root: root), capture = RequestCapture()
        for provider in ProviderID.allCases {
            var settings = AppSettings(); settings.provider = provider
            var configuration = ProviderConfiguration.defaults(for: provider)
            configuration.model = "chosen-\(provider.rawValue)"
            if provider == .compatible { configuration.baseURL = "https://example.com/v1" }
            configuration.outputLimit = provider == .codex ? 0 : 4096
            settings.providerConfigurations[provider.rawValue] = configuration
            let record = try await GenerationService(store: store).generate(provider: capture, settings: settings)
            let request = try #require(await capture.requests().last)
            #expect(request.providerID == provider)
            #expect(request.model == configuration.model)
            #expect(request.prompt == Benchmark.prompt)
            #expect(request.reasoning == configuration.reasoning)
            #expect(request.outputLimit == configuration.outputLimit)
            #expect(record.requestedModel == configuration.model)
            #expect(record.modelDisplayName == configuration.model)
            #expect(record.requestConfiguration == configuration)
            #expect(record.returnedModel == "server-snapshot")
            #expect(record.status == .success)
        }
        #expect(try store.records().count == 5)
    }
    @Test @MainActor func invalidConfigurationNeverSendsRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ResultStore(root: root), capture = RequestCapture()
        var settings = AppSettings(); settings.provider = .compatible
        do { _ = try await GenerationService(store: store).generate(provider: capture, settings: settings); Issue.record("Missing connection must fail") }
        catch let error as ProviderFailure { #expect(error.type == "invalid_model") }
        #expect(await capture.requests().isEmpty)
        #expect(try store.records().isEmpty)
    }
}
