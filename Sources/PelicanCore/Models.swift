import Foundation
import CryptoKit

public enum Benchmark {
    public static let prompt = "Generate an SVG of a pelican riding a bicycle"
    public static let id = "pelican-classic-v1"
    public static let version = "1"
    public static let model = "gpt-6-astra"
    public static let reasoning = "high"
    public static let outputLimit = 16384
    public static var promptHash: String { SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined() }
}
public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, openai, claude, gemini, compatible
    public var id: String { rawValue }
    public var title: String { descriptor.title }
    public var shortTitle: String { descriptor.shortTitle }
}
public enum GenerationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, automatic
    public var id: String { rawValue }
    public var title: String { self == .ask ? "Ask before generating" : "Generate automatically" }
}
public enum GenerationStatus: String, Codable, Sendable {
    case success, apiError = "api_error", invalidSVG = "invalid_svg", emptyResponse = "empty_response", cancelled
    case skippedByUser = "skipped_by_user", budgetLimited = "budget_limited"
    case generating, interrupted, blockedSVG = "blocked_svg", storageError = "storage_error", outputTruncated = "output_truncated"
    public var title: String {
        switch self { case .success: return "Generated"; case .apiError: return "Request failed"; case .invalidSVG: return "Invalid SVG"; case .emptyResponse: return "Empty response"; case .cancelled: return "Cancelled"; case .skippedByUser: return "Skipped"; case .budgetLimited: return "Quota or rate limited"; case .generating: return "In progress"; case .interrupted: return "Interrupted; result uncertain"; case .blockedSVG: return "Preview blocked"; case .storageError: return "Local save failed"; case .outputTruncated: return "Output truncated" }
    }
}
public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?, outputTokens: Int?, reasoningTokens: Int?, totalTokens: Int?
    static func sumKnown(_ counts: [Int?]) -> Int? {
        var sum = 0
        for count in counts {
            guard let count, count >= 0 else { return nil }
            let (next, overflow) = sum.addingReportingOverflow(count)
            guard !overflow else { return nil }
            sum = next
        }
        return sum
    }
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil, totalTokens: Int? = nil) { self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.reasoningTokens = reasoningTokens; self.totalTokens = totalTokens }
}
public struct GenerationRequest: Sendable {
    public var providerID: ProviderID
    public var model: String, prompt: String, reasoning: String
    public var outputLimit: Int
    public init(providerID: ProviderID, model: String = Benchmark.model, prompt: String = Benchmark.prompt, reasoning: String = Benchmark.reasoning, outputLimit: Int = Benchmark.outputLimit) { self.providerID = providerID; self.model = model; self.prompt = prompt; self.reasoning = reasoning; self.outputLimit = outputLimit }
}
public struct ProviderResponse: Sendable {
    public var rawResponse: String, content: String
    public var returnedModel: String?
    public var usage: TokenUsage
    public var executionProfile: String
    public init(rawResponse: String, content: String, returnedModel: String? = nil, usage: TokenUsage = .init(), executionProfile: String) { self.rawResponse = rawResponse; self.content = content; self.returnedModel = returnedModel; self.usage = usage; self.executionProfile = executionProfile }
}
public struct ProviderFailure: Error, LocalizedError, Sendable {
    public let type: String, message: String
    public let rawResponse: String?
    public let status: GenerationStatus
    public init(type: String, message: String, rawResponse: String? = nil, status: GenerationStatus = .apiError, returnedModel: String? = nil, usage: TokenUsage = .init(), executionProfile: String? = nil) { self.type = type; self.message = message; self.rawResponse = rawResponse; self.status = status; self.returnedModel = returnedModel; self.usage = usage; self.executionProfile = executionProfile }
    public let returnedModel: String?
    public let usage: TokenUsage
    public let executionProfile: String?
    public var errorDescription: String? { message }
}
public protocol ModelProvider: Sendable {
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse
    func executionProfile(for request: GenerationRequest) async -> String?
}
public extension ModelProvider {
    func executionProfile(for request: GenerationRequest) async -> String? { nil }
}
public struct ResultRecord: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var scheduledAt: Date?, startedAt: Date, completedAt: Date?
    public var providerId: ProviderID
    public var modelId: String = Benchmark.model, modelDisplayName: String = "GPT-6 Astra", requestedModel: String = Benchmark.model
    public var returnedModel: String?
    public var reasoningConfig: String = Benchmark.reasoning, outputLimit: Int = Benchmark.outputLimit
    public var benchmarkId: String = Benchmark.id, promptVersion: String = Benchmark.version, promptHash: String = Benchmark.promptHash
    public var generationMode: GenerationMode, scheduleInterval: Int
    public var status: GenerationStatus
    public var errorType: String?, errorMessage: String?, rawResponsePath: String?, svgPath: String?, thumbnailPath: String?
    public var usage: TokenUsage = .init()
    public var latencyMs: Int = 0
    public var executionProfile: String?
    public var requestConfiguration: ProviderConfiguration?
    public var annotatedSVGPath: String?
    public var annotationError: String?
    public var presentationVersion: Int?
    public var savedImagePath: String?
    public var savedSVGPath: String?
    public var imageExportError: String?
    public var seriesID: String { "\(providerId.rawValue)|\(requestedModel)|\(reasoningConfig)|\(outputLimit)|\(benchmarkId)|\(promptHash)|\(executionProfile ?? "unknown")" }
    public var configurationKnown: Bool {
        guard let executionProfile, !executionProfile.isEmpty else { return false }
        return providerId != .codex || (executionProfile.contains(";cli-version=") && !executionProfile.contains(";cli-version=unknown"))
    }
    public func configurationNote(comparedTo older: ResultRecord?) -> String? {
        guard status != .skippedByUser else { return nil }
        guard configurationKnown else { return "Configuration not fully recorded" }
        guard let older, older.configurationKnown else { return nil }
        if seriesID != older.seriesID { return "Generation settings changed" }
        if let model = returnedModel, let previous = older.returnedModel, model != previous { return "Returned model changed" }
        return nil
    }
    public func matchesSchedule(provider: ProviderID, at date: Date) -> Bool {
        providerId == provider && scheduledAt.map { Int($0.timeIntervalSince1970) == Int(date.timeIntervalSince1970) } == true
    }
    public init(providerId: ProviderID, scheduledAt: Date? = nil, startedAt: Date = Date(), completedAt: Date? = Date(), generationMode: GenerationMode, scheduleInterval: Int, status: GenerationStatus) { self.providerId = providerId; self.scheduledAt = scheduledAt; self.startedAt = startedAt; self.completedAt = completedAt; self.generationMode = generationMode; self.scheduleInterval = scheduleInterval; self.status = status }
}
public struct AppSettings: Codable, Sendable {
    public var language: AppLanguage = .chinese
    public var imageSavePath: String?
    public var provider: ProviderID = .codex
    public var intervalHours: Int = 4
    public var mode: GenerationMode = .ask
    public var nextScheduledAt: Date = Date().addingTimeInterval(4 * 3600)
    public var pendingScheduledAt: Date?
    public var retentionDays: Int = 30
    public var codexExecutable: String = ""
    public var providerConfigurations: [String: ProviderConfiguration] = [:]
    public init() {}
    public func configuration(for provider: ProviderID) -> ProviderConfiguration {
        providerConfigurations[provider.rawValue] ?? .defaults(for: provider)
    }
    public var selectedConfiguration: ProviderConfiguration { configuration(for: provider) }
    private enum CodingKeys: String, CodingKey {
        case provider, intervalHours, mode, nextScheduledAt, pendingScheduledAt, retentionDays, codexExecutable, providerConfigurations, language, imageSavePath
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .chinese
        imageSavePath = try values.decodeIfPresent(String.self, forKey: .imageSavePath)
        provider = try values.decodeIfPresent(ProviderID.self, forKey: .provider) ?? .codex
        intervalHours = try values.decodeIfPresent(Int.self, forKey: .intervalHours) ?? 4
        mode = try values.decodeIfPresent(GenerationMode.self, forKey: .mode) ?? .ask
        nextScheduledAt = try values.decodeIfPresent(Date.self, forKey: .nextScheduledAt) ?? Date().addingTimeInterval(4 * 3600)
        pendingScheduledAt = try values.decodeIfPresent(Date.self, forKey: .pendingScheduledAt)
        retentionDays = try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        codexExecutable = try values.decodeIfPresent(String.self, forKey: .codexExecutable) ?? ""
        providerConfigurations = try values.decodeIfPresent([String: ProviderConfiguration].self, forKey: .providerConfigurations) ?? [:]
    }
}
