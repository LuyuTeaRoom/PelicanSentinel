import Foundation

/// One Gemini generateContent request using the Google API key header.
public final class GeminiProvider: ModelProvider, @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let endpointRoot = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func executionProfile(for request: GenerationRequest) async -> String? {
        let endpoint = (try? endpoint(for: request)) ?? endpointRoot
        return profile(for: request, endpoint: endpoint)
    }

    public func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        let endpoint: URL
        do {
            endpoint = try self.endpoint(for: request)
        } catch let error as ProviderFailure {
            throw error
        } catch {
            throw ProviderFailure(type: "invalid_model", message: "Enter a Gemini model ID such as gemini-3.8-flash.")
        }
        let profile = profile(for: request, endpoint: endpoint)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ProviderFailure(type: "missing_api_key", message: "Gemini API key is not configured.", executionProfile: profile)
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(GeminiGenerateRequest(
                contents: [.init(role: "user", parts: [.init(text: request.prompt)])],
                generationConfig: .init(maxOutputTokens: request.outputLimit)))
        } catch {
            throw ProviderFailure(type: "request_encoding_failed", message: "Could not construct the Gemini request.", executionProfile: profile)
        }

        let result: ProviderHTTPResponse
        do {
            result = try await ProviderHTTP.postJSON(
                to: endpoint,
                headers: ["x-goog-api-key": key],
                body: body,
                session: session)
        } catch {
            throw ProviderHTTP.transportFailure(error, provider: "Gemini API", profile: profile)
        }

        let raw = String(decoding: result.data, as: UTF8.self)
        let decoded = try? JSONDecoder().decode(GeminiGenerateResponse.self, from: result.data)
        let usage = decoded?.usageMetadata?.tokenUsage ?? .init()
        guard (200...299).contains(result.response.statusCode) else {
            throw ProviderHTTP.httpFailure(
                provider: "Gemini API",
                statusCode: result.response.statusCode,
                rawResponse: raw,
                apiKey: key,
                profile: profile,
                returnedModel: decoded?.modelVersion,
                usage: usage)
        }
        guard let response = decoded else {
            throw ProviderFailure(
                type: "response_decode_failed",
                message: "Gemini returned an unreadable response.",
                rawResponse: ProviderHTTP.redacted(raw, apiKey: key),
                executionProfile: profile)
        }
        if response.promptFeedback?.blockReason != nil {
            throw failure(
                type: "gemini_prompt_blocked",
                message: "Gemini blocked the prompt.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }
        guard let candidate = response.candidates?.first else {
            throw failure(
                type: "empty_response",
                message: "Gemini did not return a candidate.",
                status: .emptyResponse,
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }
        switch candidate.finishReason {
        case "MAX_TOKENS":
            throw failure(
                type: "output_truncated",
                message: "Gemini stopped at the output limit.",
                status: .outputTruncated,
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        case "STOP":
            break
        default:
            throw failure(
                type: "gemini_finish_rejected",
                message: "Gemini ended with an unsupported finish reason.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }

        let parts = candidate.content?.parts ?? []
        guard !parts.contains(where: { $0.functionCall != nil || $0.functionResponse != nil }) else {
            throw failure(
                type: "gemini_tool_part_rejected",
                message: "Gemini returned a tool part although this generation does not enable tools.",
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }
        let text = parts.compactMap { part in
            part.thought == true ? nil : part.text
        }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure(
                type: "empty_response",
                message: "Gemini did not return text.",
                status: .emptyResponse,
                response: response,
                raw: raw,
                key: key,
                profile: profile)
        }
        return ProviderResponse(
            rawResponse: ProviderHTTP.successfulRaw(raw, apiKey: key),
            content: text,
            returnedModel: response.modelVersion,
            usage: response.usageMetadata?.tokenUsage ?? .init(),
            executionProfile: profile)
    }

    private func endpoint(for request: GenerationRequest) throws -> URL {
        let supplied = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = supplied.hasPrefix("models/") ? String(supplied.dropFirst("models/".count)) : supplied
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !model.isEmpty, model.unicodeScalars.allSatisfy(permitted.contains) else {
            throw ProviderFailure(type: "invalid_model", message: "Enter a Gemini model ID such as gemini-3.8-flash.")
        }
        return endpointRoot.appendingPathComponent("\(model):generateContent")
    }

    private func profile(for request: GenerationRequest, endpoint: URL) -> String {
        "gemini-generate-content-v1;endpoint=\(endpoint.absoluteString);single-user;no-tools;max-output-tokens=\(request.outputLimit)"
    }

    private func failure(
        type: String,
        message: String,
        status: GenerationStatus = .apiError,
        response: GeminiGenerateResponse,
        raw: String,
        key: String,
        profile: String) -> ProviderFailure
    {
        ProviderFailure(
            type: type,
            message: message,
            rawResponse: ProviderHTTP.redacted(raw, apiKey: key),
            status: status,
            returnedModel: response.modelVersion,
            usage: response.usageMetadata?.tokenUsage ?? .init(),
            executionProfile: profile)
    }
}

private struct GeminiGenerateRequest: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            let text: String
        }

        let role: String
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let maxOutputTokens: Int
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GeminiGenerateResponse: Decodable {
    struct PromptFeedback: Decodable {
        let blockReason: String?
    }

    struct Content: Decodable {
        let parts: [Part]?
    }

    struct Part: Decodable {
        let text: String?
        let thought: Bool?
        let functionCall: IgnoredJSONValue?
        let functionResponse: IgnoredJSONValue?

        enum CodingKeys: String, CodingKey {
            case text, thought
            case functionCall = "functionCall"
            case functionResponse = "functionResponse"
        }
    }

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let thoughtsTokenCount: Int?
        let totalTokenCount: Int?

        var tokenUsage: TokenUsage {
            let outputTokens = TokenUsage.sumKnown([candidatesTokenCount, thoughtsTokenCount ?? 0])
            let totalTokens = totalTokenCount ?? TokenUsage.sumKnown([promptTokenCount, outputTokens])
            return TokenUsage(
                inputTokens: promptTokenCount,
                outputTokens: outputTokens,
                reasoningTokens: thoughtsTokenCount,
                totalTokens: totalTokens)
        }
    }

    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
    let usageMetadata: UsageMetadata?
    let modelVersion: String?
}
