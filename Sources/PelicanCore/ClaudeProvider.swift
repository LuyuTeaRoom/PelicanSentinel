import Foundation

/// One stateless Claude Messages API generation. It intentionally sends no
/// conversation history, tools, retries, browser state, or OAuth credentials.
public final class ClaudeProvider: ModelProvider, @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func executionProfile(for request: GenerationRequest) async -> String? {
        profile(for: request)
    }

    public func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        let profile = profile(for: request)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ProviderFailure(type: "missing_api_key", message: "Claude API key is not configured.", executionProfile: profile)
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(ClaudeMessageRequest(
                model: request.model,
                maxTokens: request.outputLimit,
                messages: [.init(role: "user", content: request.prompt)]))
        } catch {
            throw ProviderFailure(type: "request_encoding_failed", message: "Could not construct the Claude request.", executionProfile: profile)
        }

        let result: ProviderHTTPResponse
        do {
            result = try await ProviderHTTP.postJSON(
                to: endpoint,
                headers: ["X-Api-Key": key, "anthropic-version": "2023-06-01"],
                body: body,
                session: session)
        } catch {
            throw ProviderHTTP.transportFailure(error, provider: "Claude API", profile: profile)
        }

        let raw = String(decoding: result.data, as: UTF8.self)
        let decoded = try? JSONDecoder().decode(ClaudeMessageResponse.self, from: result.data)
        let usage = decoded?.usage?.tokenUsage ?? .init()
        guard (200...299).contains(result.response.statusCode) else {
            throw ProviderHTTP.httpFailure(
                provider: "Claude API",
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
                message: "Claude returned an unreadable response.",
                rawResponse: ProviderHTTP.redacted(raw, apiKey: key),
                executionProfile: profile)
        }

        switch response.stopReason {
        case "max_tokens", "model_context_window_exceeded":
            throw failure(
                type: "output_truncated",
                message: "Claude stopped at its output or context limit.",
                status: .outputTruncated,
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        case "refusal":
            throw failure(
                type: "claude_refusal",
                message: "Claude refused this request.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        case "tool_use":
            throw failure(
                type: "claude_tool_use_rejected",
                message: "Claude requested a tool although this generation does not enable tools.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        case "end_turn", "stop_sequence":
            break
        default:
            throw failure(
                type: "claude_stop_rejected",
                message: "Claude ended with an unsupported stop reason.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }

        guard !response.content.contains(where: { $0.type == "tool_use" || $0.type == "server_tool_use" }) else {
            throw failure(
                type: "claude_tool_use_rejected",
                message: "Claude returned a tool block although this generation does not enable tools.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }

        let text = response.content.compactMap { block in
            block.type == "text" ? block.text : nil
        }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure(
                type: "empty_response",
                message: "Claude did not return text.",
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
        "claude-messages-v1;endpoint=\(endpoint.absoluteString);single-user;no-history;no-tools;max-tokens=\(request.outputLimit)"
    }

    private func failure(
        type: String,
        message: String,
        status: GenerationStatus = .apiError,
        response: ClaudeMessageResponse,
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

private struct ClaudeMessageRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let maxTokens: Int
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
    }
}

private struct ClaudeMessageResponse: Decodable {
    struct Content: Decodable {
        let type: String?
        let text: String?
    }

    struct Usage: Decodable {
        struct OutputDetails: Decodable {
            let thinkingTokens: Int?

            enum CodingKeys: String, CodingKey {
                case thinkingTokens = "thinking_tokens"
            }
        }

        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?
        let outputTokensDetails: OutputDetails?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case outputTokensDetails = "output_tokens_details"
        }

        var tokenUsage: TokenUsage {
            let input = TokenUsage.sumKnown([inputTokens, cacheCreationInputTokens ?? 0, cacheReadInputTokens ?? 0])
            return TokenUsage(
                inputTokens: input,
                outputTokens: outputTokens,
                reasoningTokens: outputTokensDetails?.thinkingTokens,
                totalTokens: TokenUsage.sumKnown([input, outputTokens]))
        }
    }

    let model: String?
    let content: [Content]
    let stopReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case model, content, usage
        case stopReason = "stop_reason"
    }
}
