import Foundation

/// The small, fixed catalog keeps connection labels, defaults and capabilities together.
public struct ProviderDescriptor: Sendable {
    public let title: String
    public let shortTitle: String
    public let authenticationHint: String
    public let defaultModel: String
    public let reasoningOptions: [String]
    public let usesCLI: Bool
    public let allowsCustomEndpoint: Bool
}

public extension ProviderID {
    var descriptor: ProviderDescriptor {
        switch self {
        case .codex:
            return .init(title: "Codex (ChatGPT sign-in)", shortTitle: "Codex", authenticationHint: "Uses the ChatGPT sign-in in your local Codex CLI. Run codex login in Terminal first.", defaultModel: Benchmark.model, reasoningOptions: ["low", "medium", "high", "xhigh", "max", "ultra"], usesCLI: true, allowsCustomEndpoint: false)
        case .openai:
            return .init(title: "OpenAI API", shortTitle: "OpenAI", authenticationHint: "Uses an OpenAI API key and separate API billing. ChatGPT subscriptions do not include API credits.", defaultModel: Benchmark.model, reasoningOptions: ["default", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"], usesCLI: false, allowsCustomEndpoint: false)
        case .claude:
            return .init(title: "Claude API", shortTitle: "Claude", authenticationHint: "Uses an Anthropic API key with the Messages API. Claude app subscriptions are separate.", defaultModel: "claude-sonnet-5", reasoningOptions: [], usesCLI: false, allowsCustomEndpoint: false)
        case .gemini:
            return .init(title: "Gemini API", shortTitle: "Gemini", authenticationHint: "Uses a Google AI Studio API key with Gemini generateContent. Gemini app subscriptions are separate.", defaultModel: "gemini-3.8-flash", reasoningOptions: [], usesCLI: false, allowsCustomEndpoint: false)
        case .compatible:
            return .init(title: "OpenAI-compatible API", shortTitle: "Compatible", authenticationHint: "Uses Chat Completions at your chosen base URL. The key is stored separately for each address. Local servers may not require a key.", defaultModel: "", reasoningOptions: [], usesCLI: false, allowsCustomEndpoint: true)
        }
    }
}

public enum TokenLimitField: String, Codable, CaseIterable, Identifiable, Sendable {
    case maxTokens = "max_tokens", maxCompletionTokens = "max_completion_tokens"
    public var id: String { rawValue }
}

public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public var model: String
    /// "default" means no reasoning override is sent to the API.
    public var reasoning: String
    public var outputLimit: Int
    public var baseURL: String
    public var tokenLimitField: TokenLimitField

    public init(model: String, reasoning: String = "default", outputLimit: Int = Benchmark.outputLimit, baseURL: String = "", tokenLimitField: TokenLimitField = .maxTokens) {
        self.model = model; self.reasoning = reasoning; self.outputLimit = outputLimit
        self.baseURL = baseURL; self.tokenLimitField = tokenLimitField
    }
    public static func defaults(for provider: ProviderID) -> Self {
        .init(model: provider.descriptor.defaultModel,
              reasoning: [.codex, .openai].contains(provider) ? Benchmark.reasoning : "default",
              outputLimit: provider == .codex ? 0 : Benchmark.outputLimit)
    }
    public func validated(for provider: ProviderID) throws -> Self {
        var result = self
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.model.isEmpty, result.model.count <= 200,
              result.model.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              result.model.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ProviderFailure(type: "invalid_model", message: "Enter a valid model ID for this connection.")
        }
        let descriptor = provider.descriptor
        if descriptor.reasoningOptions.isEmpty { result.reasoning = "default" }
        else if !descriptor.reasoningOptions.contains(reasoning) {
            throw ProviderFailure(type: "invalid_reasoning", message: "Choose a supported reasoning setting.")
        }
        if descriptor.usesCLI { result.outputLimit = 0 }
        else if !(1...131_072).contains(outputLimit) {
            throw ProviderFailure(type: "invalid_output_limit", message: "The output limit must be between 1 and 131,072 tokens. Model limits still apply.")
        }
        result.baseURL = descriptor.allowsCustomEndpoint ? try CompatibleEndpoint.normalizedBaseURL(baseURL) : ""
        if !descriptor.allowsCustomEndpoint { result.tokenLimitField = .maxTokens }
        return result
    }
    public func request(for provider: ProviderID) throws -> GenerationRequest {
        let valid = try validated(for: provider)
        return GenerationRequest(providerID: provider, model: valid.model, reasoning: valid.reasoning, outputLimit: valid.outputLimit)
    }
}

public enum CompatibleEndpoint {
    public static func normalizedBaseURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme?.lowercased() == "https" || (parts.scheme?.lowercased() == "http" && isLoopback(host)) else {
            throw ProviderFailure(type: "invalid_endpoint", message: "Enter an HTTPS base URL without credentials, query or fragment. HTTP is allowed only for localhost, 127.0.0.1 or [::1].")
        }
        parts.scheme = parts.scheme?.lowercased(); parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard !parts.path.hasSuffix("/chat/completions"), !parts.path.hasSuffix("/responses"),
              !parts.path.contains(".."), parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url else {
            throw ProviderFailure(type: "invalid_endpoint", message: "Enter the API base URL, such as https://example.com/v1, without /chat/completions or /responses.")
        }
        return url.absoluteString
    }
    public static func completionURL(_ baseURL: String) throws -> URL {
        URL(string: try normalizedBaseURL(baseURL))!.appendingPathComponent("chat/completions")
    }
    public static func isLocal(_ baseURL: String) -> Bool {
        URLComponents(string: baseURL)?.host.map(isLoopback) ?? false
    }
    private static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
}
