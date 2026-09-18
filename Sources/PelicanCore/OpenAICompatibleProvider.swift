import Foundation

/// A deliberately narrow OpenAI Chat Completions adapter. Compatibility means
/// this one request/response contract only; it does not enable tool loops or
/// provider-specific extensions.
public final class OpenAICompatibleProvider: ModelProvider, @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL
    private let tokenLimitField: TokenLimitField
    private let requiresAuthorization: Bool

    public init(
        apiKey: String,
        baseURL: String,
        tokenLimitField: TokenLimitField,
        session: URLSession = .shared) throws
    {
        self.apiKey = apiKey
        self.endpoint = try CompatibleEndpoint.completionURL(baseURL)
        self.tokenLimitField = tokenLimitField
        self.session = session
        self.requiresAuthorization = !CompatibleEndpoint.isLocal(baseURL)
        if requiresAuthorization && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProviderFailure(type: "missing_api_key", message: "An API key is required for a remote compatible endpoint.")
        }
    }

    public func executionProfile(for request: GenerationRequest) async -> String? {
        profile(for: request)
    }

    public func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        let profile = profile(for: request)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requiresAuthorization || !key.isEmpty else {
            throw ProviderFailure(type: "missing_api_key", message: "An API key is required for a remote compatible endpoint.", executionProfile: profile)
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(OpenAICompatibleRequest(
                model: request.model,
                messages: [.init(role: "user", content: request.prompt)],
                outputLimit: request.outputLimit,
                tokenLimitField: tokenLimitField))
        } catch {
            throw ProviderFailure(type: "request_encoding_failed", message: "Could not construct the compatible Chat Completions request.", executionProfile: profile)
        }

        var headers: [String: String] = [:]
        if !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }
        let result: ProviderHTTPResponse
        do {
            result = try await ProviderHTTP.postJSON(to: endpoint, headers: headers, body: body, session: session)
        } catch {
            throw ProviderHTTP.transportFailure(error, provider: "OpenAI-compatible API", profile: profile)
        }

        let raw = String(decoding: result.data, as: UTF8.self)
        let decoded = try? JSONDecoder().decode(OpenAICompatibleResponse.self, from: result.data)
        let usage = decoded?.usage?.tokenUsage ?? .init()
        guard (200...299).contains(result.response.statusCode) else {
            throw ProviderHTTP.httpFailure(
                provider: "OpenAI-compatible API",
                statusCode: result.response.statusCode,
                rawResponse: raw,
                apiKey: key,
                profile: profile,
                returnedModel: decoded?.model,
                usage: usage)
        }
        guard let response = decoded else {
            throw ProviderFailure(
                type: "response_decode_failed",
                message: "The compatible endpoint returned an unreadable response.",
                rawResponse: ProviderHTTP.redacted(raw, apiKey: key),
                executionProfile: profile)
        }
        guard let choice = response.choices?.first,
              let message = choice.message,
              message.role == "assistant"
        else {
            throw failure(
                type: "empty_response",
                message: "The compatible endpoint did not return an assistant choice.",
                status: .emptyResponse,
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }
        switch choice.finishReason {
        case "length":
            throw failure(
                type: "output_truncated",
                message: "The compatible endpoint stopped at the output limit.",
                status: .outputTruncated,
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        case "stop":
            break
        default:
            throw failure(
                type: "compatible_finish_rejected",
                message: "The compatible endpoint ended with an unsupported finish reason.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }
        let hasToolCalls = !(message.toolCalls?.isEmpty ?? true)
        guard !hasToolCalls, message.functionCall == nil else {
            throw failure(
                type: "compatible_tool_rejected",
                message: "The compatible endpoint returned a tool call although this generation does not enable tools.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }
        guard message.refusal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw failure(
                type: "compatible_refusal",
                message: "The compatible endpoint refused this request.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }
        guard let text = message.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure(
                type: "empty_response",
                message: "The compatible endpoint did not return text.",
                status: .emptyResponse,
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }
        return ProviderResponse(
            rawResponse: ProviderHTTP.successfulRaw(raw, apiKey: key),
            content: text,
            returnedModel: response.model,
            usage: response.usage?.tokenUsage ?? .init(),
            executionProfile: profile)
    }

    private func profile(for request: GenerationRequest) -> String {
        "openai-compatible-chat-completions-v1;endpoint=\(endpoint.absoluteString);single-user;no-tools;token-field=\(tokenLimitField.rawValue);output-limit=\(request.outputLimit)"
    }

    private func failure(
        type: String,
        message: String,
        status: GenerationStatus = .apiError,
        response: OpenAICompatibleResponse,
        raw: String,
        key: String,
        profile: String) -> ProviderFailure
    {
        ProviderFailure(
            type: type,
            message: message,
            rawResponse: ProviderHTTP.redacted(raw, apiKey: key),
            status: status,
            returnedModel: response.model,
            usage: response.usage?.tokenUsage ?? .init(),
            executionProfile: profile)
    }
}

private struct OpenAICompatibleRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let outputLimit: Int
    let tokenLimitField: TokenLimitField

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        switch tokenLimitField {
        case .maxTokens:
            try container.encode(outputLimit, forKey: .maxTokens)
        case .maxCompletionTokens:
            try container.encode(outputLimit, forKey: .maxCompletionTokens)
        }
    }
}

private struct OpenAICompatibleResponse: Decodable {
    struct Message: Decodable {
        let role: String?
        let content: String?
        let refusal: String?
        let toolCalls: [IgnoredJSONValue]?
        let functionCall: IgnoredJSONValue?

        enum CodingKeys: String, CodingKey {
            case role, content, refusal
            case toolCalls = "tool_calls"
            case functionCall = "function_call"
        }
    }

    struct Choice: Decodable {
        let message: Message?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        struct CompletionDetails: Decodable {
            let reasoningTokens: Int?

            enum CodingKeys: String, CodingKey {
                case reasoningTokens = "reasoning_tokens"
            }
        }

        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let completionTokensDetails: CompletionDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case completionTokensDetails = "completion_tokens_details"
        }

        var tokenUsage: TokenUsage {
            TokenUsage(
                inputTokens: promptTokens,
                outputTokens: completionTokens,
                reasoningTokens: completionTokensDetails?.reasoningTokens,
                totalTokens: totalTokens)
        }
    }

    let model: String?
    let choices: [Choice]?
    let usage: Usage?
}
