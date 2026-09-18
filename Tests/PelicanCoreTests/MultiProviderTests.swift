import Foundation
import Testing
@testable import PelicanCore

@Suite(.serialized)
struct MultiProviderTests {
    @Test
    func claudeSendsMessagesRequestAndPreservesSVGText() async throws {
        defer { MultiProviderURLProtocol.handler = nil }
        let apiKey = "anthropic-test-secret"
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        let responseBody = #"""
        {"model":"claude-sonnet-5-20260901","trace":"anthropic-test-secret","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"<svg id=\"sk-wheel\">"},{"type":"text","text":"</svg>"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":6,"output_tokens_details":{"thinking_tokens":1}}}
        """#
        MultiProviderURLProtocol.handler = { request in
            capturedRequest = request
            capturedBody = request.httpBody ?? multiBodyData(from: request.httpBodyStream)
            return .response(status: 200, body: responseBody)
        }

        let request = GenerationRequest(providerID: .claude, model: "claude-sonnet-5", prompt: "draw", outputLimit: 321)
        let result = try await ClaudeProvider(apiKey: apiKey, session: multiStubSession()).generate(request)

        #expect(capturedRequest?.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.value(forHTTPHeaderField: "X-Api-Key") == apiKey)
        #expect(capturedRequest?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let payload = try #require(capturedBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(body["model"] as? String == "claude-sonnet-5")
        #expect(body["max_tokens"] as? Int == 321)
        #expect(((body["messages"] as? [[String: Any]])?.first?["role"] as? String) == "user")
        #expect(((body["messages"] as? [[String: Any]])?.first?["content"] as? String) == "draw")
        #expect(body["tools"] == nil)
        #expect(result.content == "<svg id=\"sk-wheel\"></svg>")
        #expect(result.usage == TokenUsage(inputTokens: 9, outputTokens: 6, reasoningTokens: 1, totalTokens: 15))
        #expect(result.rawResponse.contains("sk-wheel"))
        #expect(!result.rawResponse.contains(apiKey))
        #expect(result.rawResponse.contains("[REDACTED]"))
    }

    @Test
    func claudeRejectsToolBlockEvenWhenStopReasonIsEndTurn() async throws {
        defer { MultiProviderURLProtocol.handler = nil }
        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"""
            {"model":"claude-sonnet-5","content":[{"type":"text","text":"<svg/>"},{"type":"server_tool_use"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":3}}
            """#)
        }

        do {
            _ = try await ClaudeProvider(apiKey: "anthropic-test", session: multiStubSession())
                .generate(GenerationRequest(providerID: .claude))
            Issue.record("Expected a tool-use failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "claude_tool_use_rejected")
            #expect(failure.usage == TokenUsage(inputTokens: 2, outputTokens: 3, totalTokens: 5))
        }

        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"""
            {"model":"claude-sonnet-5","content":[{"type":"text","text":"partial"}],"stop_reason":"model_context_window_exceeded","usage":{"input_tokens":2,"output_tokens":3}}
            """#)
        }
        do {
            _ = try await ClaudeProvider(apiKey: "anthropic-test", session: multiStubSession())
                .generate(GenerationRequest(providerID: .claude))
            Issue.record("Expected a truncation failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "output_truncated")
            #expect(failure.status == .outputTruncated)
        }
    }

    @Test
    func geminiUsesHeaderFiltersThoughtsAndCountsReasoningInOutput() async throws {
        defer { MultiProviderURLProtocol.handler = nil }
        let apiKey = "AIza-test-key"
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        MultiProviderURLProtocol.handler = { request in
            capturedRequest = request
            capturedBody = request.httpBody ?? multiBodyData(from: request.httpBodyStream)
            return .response(status: 200, body: #"""
            {"modelVersion":"gemini-3.8-flash-001","candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"internal"},{"text":"<svg id=\"sk-wheel\"/>"}]}}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":7,"thoughtsTokenCount":2,"totalTokenCount":14}}
            """#)
        }

        let request = GenerationRequest(providerID: .gemini, model: "models/gemini-3.8-flash", prompt: "draw", outputLimit: 222)
        let result = try await GeminiProvider(apiKey: apiKey, session: multiStubSession()).generate(request)

        #expect(capturedRequest?.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        #expect(capturedRequest?.url?.query == nil)
        #expect(capturedRequest?.value(forHTTPHeaderField: "x-goog-api-key") == apiKey)
        let payload = try #require(capturedBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect((((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String) == "draw")
        #expect((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 222)
        #expect(result.content == "<svg id=\"sk-wheel\"/>")
        #expect(result.usage == TokenUsage(inputTokens: 5, outputTokens: 9, reasoningTokens: 2, totalTokens: 14))
    }

    @Test
    func geminiRejectsBlockedAndTruncatedResponsesAndInvalidModelIDs() async throws {
        defer { MultiProviderURLProtocol.handler = nil }
        let provider = GeminiProvider(apiKey: "AIza-test", session: multiStubSession())
        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"""
            {"modelVersion":"gemini-3.8-flash","promptFeedback":{"blockReason":"SAFETY"},"usageMetadata":{"promptTokenCount":4,"totalTokenCount":4}}
            """#)
        }
        do {
            _ = try await provider.generate(GenerationRequest(providerID: .gemini))
            Issue.record("Expected a prompt-block failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "gemini_prompt_blocked")
            #expect(failure.usage.inputTokens == 4)
        }

        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"""
            {"modelVersion":"gemini-3.8-flash","candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"partial"}]}}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":6,"thoughtsTokenCount":2,"totalTokenCount":12}}
            """#)
        }
        do {
            _ = try await provider.generate(GenerationRequest(providerID: .gemini))
            Issue.record("Expected a truncation failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "output_truncated")
            #expect(failure.status == .outputTruncated)
            #expect(failure.usage == TokenUsage(inputTokens: 4, outputTokens: 8, reasoningTokens: 2, totalTokens: 12))
        }

        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"""
            {"modelVersion":"gemini-3.8-flash","candidates":[{"finishReason":"STOP","content":{"parts":[{"functionCall":{"name":"lookup"}}]}}]}
            """#)
        }
        do {
            _ = try await provider.generate(GenerationRequest(providerID: .gemini))
            Issue.record("Expected a tool-part failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "gemini_tool_part_rejected")
        }

        do {
            _ = try await provider.generate(GenerationRequest(providerID: .gemini, model: "gemini-3.8-flash?alt=media"))
            Issue.record("Expected an invalid-model failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "invalid_model")
        }
    }

    @Test
    func compatibleUsesChosenTokenFieldAndTreatsEmptyToolFieldsAsAbsent() async throws {
        defer { MultiProviderURLProtocol.handler = nil }
        let apiKey = "sk-compatible-test"
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        MultiProviderURLProtocol.handler = { request in
            capturedRequest = request
            capturedBody = request.httpBody ?? multiBodyData(from: request.httpBodyStream)
            return .response(status: 200, body: #"""
            {"model":"compat-model-1","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"<svg id=\"sk-wheel\"/>","tool_calls":[],"refusal":""}},{"finish_reason":"stop","message":{"role":"assistant","content":"ignored"}}],"usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8,"completion_tokens_details":{"reasoning_tokens":2}}}
            """#)
        }

        let provider = try OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: "https://gateway.example/v1",
            tokenLimitField: .maxCompletionTokens,
            session: multiStubSession())
        let result = try await provider.generate(GenerationRequest(providerID: .compatible, model: "compat-model", prompt: "draw", outputLimit: 88))

        #expect(capturedRequest?.url?.absoluteString == "https://gateway.example/v1/chat/completions")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        let payload = try #require(capturedBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(body["max_completion_tokens"] as? Int == 88)
        #expect(body["max_tokens"] == nil)
        #expect(body["reasoning"] == nil)
        #expect(result.content == "<svg id=\"sk-wheel\"/>")
        #expect(result.usage == TokenUsage(inputTokens: 3, outputTokens: 5, reasoningTokens: 2, totalTokens: 8))
        #expect(result.rawResponse.contains("sk-wheel"))

        var localRequest: URLRequest?
        var localBody: Data?
        MultiProviderURLProtocol.handler = { request in
            localRequest = request
            localBody = request.httpBody ?? multiBodyData(from: request.httpBodyStream)
            return .response(status: 200, body: #"""
            {"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"<svg/>"}}]}
            """#)
        }
        let localProvider = try OpenAICompatibleProvider(
            apiKey: "",
            baseURL: "http://localhost:8080/v1",
            tokenLimitField: .maxTokens,
            session: multiStubSession())
        _ = try await localProvider.generate(GenerationRequest(providerID: .compatible, outputLimit: 55))
        #expect(localRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        let localPayload = try #require(localBody)
        let localJSON = try #require(try JSONSerialization.jsonObject(with: localPayload) as? [String: Any])
        #expect(localJSON["max_tokens"] as? Int == 55)
        #expect(localJSON["max_completion_tokens"] == nil)
    }

    @Test
    func compatibleRejectsSubstantiveToolOrRefusalAndMapsRateLimits() async throws {
        defer { MultiProviderURLProtocol.handler = nil }
        let provider = try OpenAICompatibleProvider(
            apiKey: "sk-compatible-test",
            baseURL: "http://localhost:8080/v1",
            tokenLimitField: .maxTokens,
            session: multiStubSession())

        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"""
            {"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"partial"}}]}
            """#)
        }
        do {
            _ = try await provider.generate(GenerationRequest(providerID: .compatible))
            Issue.record("Expected a truncation failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "output_truncated")
            #expect(failure.status == .outputTruncated)
        }

        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"""
            {"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"<svg/>","tool_calls":[{"id":"call_1"}]}}]}
            """#)
        }
        do {
            _ = try await provider.generate(GenerationRequest(providerID: .compatible))
            Issue.record("Expected a tool-use failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "compatible_tool_rejected")
        }

        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"""
            {"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"<svg/>","refusal":"cannot comply"}}]}
            """#)
        }
        do {
            _ = try await provider.generate(GenerationRequest(providerID: .compatible))
            Issue.record("Expected a refusal failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "compatible_refusal")
        }

        MultiProviderURLProtocol.handler = { _ in .response(status: 429, body: #"{"error":"limit"}"#) }
        do {
            _ = try await provider.generate(GenerationRequest(providerID: .compatible))
            Issue.record("Expected a rate-limit failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "rate_limited")
            #expect(failure.status == .budgetLimited)
        }
    }

    @Test
    func incompleteUsageDoesNotBecomeAnInventedTotal() async throws {
        defer { MultiProviderURLProtocol.handler = nil }
        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"{"content":[{"type":"text","text":"<svg/>"}],"stop_reason":"end_turn","usage":{"output_tokens":7}}"#)
        }
        let claude = try await ClaudeProvider(apiKey: "fixture", session: multiStubSession()).generate(GenerationRequest(providerID: .claude))
        #expect(claude.usage.inputTokens == nil)
        #expect(claude.usage.outputTokens == 7)
        #expect(claude.usage.totalTokens == nil)
        MultiProviderURLProtocol.handler = { _ in
            .response(status: 200, body: #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"<svg/>"}]}}],"usageMetadata":{"promptTokenCount":5,"thoughtsTokenCount":2}}"#)
        }
        let gemini = try await GeminiProvider(apiKey: "fixture", session: multiStubSession()).generate(GenerationRequest(providerID: .gemini, model: "gemini-3.8-flash"))
        #expect(gemini.usage.outputTokens == nil)
        #expect(gemini.usage.reasoningTokens == 2)
        #expect(gemini.usage.totalTokens == nil)
    }

    @Test
    func compatibleValidatesEndpointAndMapsCancelledTransport() async throws {
        do {
            _ = try OpenAICompatibleProvider(apiKey: "", baseURL: "https://gateway.example/v1", tokenLimitField: .maxTokens)
            Issue.record("Expected a remote-key failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "missing_api_key")
        }
        do {
            _ = try OpenAICompatibleProvider(apiKey: "", baseURL: "http://example.com/v1", tokenLimitField: .maxTokens)
            Issue.record("Expected an endpoint failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "invalid_endpoint")
        }

        defer { MultiProviderURLProtocol.handler = nil }
        MultiProviderURLProtocol.handler = { _ in .error(URLError(.cancelled)) }
        do {
            _ = try await GeminiProvider(apiKey: "AIza-test", session: multiStubSession()).generate(GenerationRequest(providerID: .gemini))
            Issue.record("Expected a cancellation failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "cancelled")
            #expect(failure.status == .cancelled)
        }
    }
}

private func multiStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MultiProviderURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func multiBodyData(from stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private enum MultiProviderStubReply {
    case response(status: Int, body: String)
    case error(URLError)
}

private final class MultiProviderURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> MultiProviderStubReply)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            Issue.record("Missing URLProtocol handler")
            return
        }
        switch handler(request) {
        case let .response(status, body):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://stub.invalid")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
