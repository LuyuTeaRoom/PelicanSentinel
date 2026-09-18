import Foundation
import Testing
@testable import PelicanCore

@Suite(.serialized)
struct ProviderTests {
    @Test
    func openAIProviderSendsExactFirstShotRequestAndParsesCompletedResponse() async throws {
        defer { StubURLProtocol.handler = nil }
        let expectedKey = "sk-test-only"
        let session = stubSession()
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            capturedBody = request.httpBody ?? bodyData(from: request.httpBodyStream)
            return response(status: 200, body: completedResponse)
        }

        let provider = OpenAIProvider(apiKey: expectedKey, session: session)
        let request = GenerationRequest(providerID: .openai, model: "gpt-6-astra", prompt: "Generate an SVG of a pelican riding a bicycle", reasoning: "high", outputLimit: 1234)
        let result = try await provider.generate(request)

        #expect(capturedRequest?.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer \(expectedKey)")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let payload = try #require(capturedBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(body["model"] as? String == request.model)
        #expect(body["input"] as? String == request.prompt)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == request.reasoning)
        #expect(body["max_output_tokens"] as? Int == request.outputLimit)
        #expect(body["store"] as? Bool == false)
        #expect(body["tools"] == nil)
        #expect(body["instructions"] == nil)
        #expect(body["previous_response_id"] == nil)
        #expect(result.content == "<svg/>\n")
        #expect(result.returnedModel == "gpt-6-astra-2026-09-15")
        #expect(result.usage == TokenUsage(inputTokens: 11, outputTokens: 17, reasoningTokens: 3, totalTokens: 28))
        #expect(result.rawResponse == completedResponse)
        #expect(result.executionProfile.contains("no-context"))
        #expect(result.executionProfile.contains("no-tools"))
    }

    @Test
    func openAIProviderAggregatesAllAssistantMessageTextInOrder() async throws {
        defer { StubURLProtocol.handler = nil }
        let body = #"""
        {"model":"gpt-6-astra-2026-09-15","status":"completed","output":[{"type":"reasoning","content":[{"type":"output_text","text":"ignored reasoning"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<sv"},{"type":"refusal","refusal":"ignored"},{"type":"output_text","text":"g viewBox=\"0 0 1 1\">"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<path/>"},{"type":"output_text","text":"</svg>"}]},{"type":"message","role":"user","content":[{"type":"output_text","text":"ignored user"}]}]}
        """#
        StubURLProtocol.handler = { _ in response(status: 200, body: body) }

        let result = try await OpenAIProvider(apiKey: "sk-test-only", session: stubSession())
            .generate(GenerationRequest(providerID: .openai))

        #expect(result.content == "<svg viewBox=\"0 0 1 1\"><path/></svg>")
    }

    @Test
    func openAIProviderOmitsDefaultReasoningOverride() async throws {
        defer { StubURLProtocol.handler = nil }
        var capturedBody: Data?
        StubURLProtocol.handler = { request in
            capturedBody = request.httpBody ?? bodyData(from: request.httpBodyStream)
            return response(status: 200, body: completedResponse)
        }

        let request = GenerationRequest(providerID: .openai, reasoning: "default")
        let result = try await OpenAIProvider(apiKey: "sk-test-only", session: stubSession()).generate(request)
        let payload = try #require(capturedBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])

        #expect(body["reasoning"] == nil)
        #expect(result.executionProfile.contains("reasoning=default"))
    }

    @Test
    func openAIProviderRedactsSensitiveHTTPFailure() async throws {
        defer { StubURLProtocol.handler = nil }
        StubURLProtocol.handler = { _ in response(status: 401, body: #"{"error":{"message":"Bearer sk-secret-value must never be stored"}}"#) }
        do {
            _ = try await OpenAIProvider(apiKey: "sk-test-only", session: stubSession()).generate(GenerationRequest(providerID: .openai))
            Issue.record("Expected a ProviderFailure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "http_401")
            #expect(failure.status == .apiError)
            #expect(!failure.message.contains("sk-secret-value"))
            #expect(!(failure.rawResponse ?? "").contains("sk-secret-value"))
        }
    }

    @Test
    func openAIProviderClassifiesRateLimitAsBudgetLimited() async throws {
        defer { StubURLProtocol.handler = nil }
        StubURLProtocol.handler = { _ in response(status: 429, body: #"{"error":{"message":"limit"}}"#) }
        do {
            _ = try await OpenAIProvider(apiKey: "sk-test-only", session: stubSession()).generate(GenerationRequest(providerID: .openai))
            Issue.record("Expected a ProviderFailure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "rate_limited")
            #expect(failure.status == .budgetLimited)
        }
    }

    @Test
    func openAIProviderRejectsTruncatedAndErroredResponses() async throws {
        defer { StubURLProtocol.handler = nil }
        let session = stubSession()
        let truncated = #"{"model":"gpt-6-astra-2026-09-15","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[],"usage":{"input_tokens":11,"output_tokens":17,"total_tokens":28,"output_tokens_details":{"reasoning_tokens":3}}}"#
        StubURLProtocol.handler = { _ in response(status: 200, body: truncated) }
        do {
            _ = try await OpenAIProvider(apiKey: "sk-test-only", session: session).generate(GenerationRequest(providerID: .openai))
            Issue.record("Expected a truncation failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "output_truncated")
            #expect(failure.status == .outputTruncated)
            #expect(failure.rawResponse == truncated)
            #expect(failure.returnedModel == "gpt-6-astra-2026-09-15")
            #expect(failure.usage == TokenUsage(inputTokens: 11, outputTokens: 17, reasoningTokens: 3, totalTokens: 28))
            #expect(failure.executionProfile?.contains("openai-responses-v1") == true)
        }

        StubURLProtocol.handler = { _ in response(status: 200, body: #"{"model":"gpt-6-astra-2026-09-15","status":"failed","error":{"code":"server_error"},"output":[],"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}"#) }
        do {
            _ = try await OpenAIProvider(apiKey: "sk-test-only", session: session).generate(GenerationRequest(providerID: .openai))
            Issue.record("Expected an incomplete response failure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "response_not_completed")
            #expect(failure.status == .apiError)
            #expect(failure.returnedModel == "gpt-6-astra-2026-09-15")
            #expect(failure.usage == TokenUsage(inputTokens: 2, outputTokens: 3, reasoningTokens: nil, totalTokens: 5))
            #expect(failure.executionProfile?.contains("openai-responses-v1") == true)
        }
    }

    @Test
    func codexJSONLAcceptsOnlyOneFinalMessage() throws {
        let valid = """
        {"type":"thread.started","thread_id":"thread"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item","type":"agent_message","text":"<svg/>"}}
        {"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":24,"reasoning_output_tokens":5}}
        """
        let parsed = try CodexProvider.parseJSONL(valid)
        #expect(parsed.content == "<svg/>")
        #expect(parsed.usage == TokenUsage(inputTokens: 12, outputTokens: 24, reasoningTokens: 5, totalTokens: 36))
    }

    @Test
    func codexJSONLRejectsToolActivityAndMultipleTurns() {
        let toolActivity = """
        {"type":"thread.started"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"command_execution"}}
        {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
        """
        assertCodexFailure(toolActivity, type: "codex_activity_rejected")
        let multipleTurns = """
        {"type":"thread.started"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"<svg/>"}}
        {"type":"turn.started"}
        {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
        """
        assertCodexFailure(multipleTurns, type: "codex_activity_rejected")
    }

    @Test
    func codexProviderRecordsVersionAndUsesIsolatedArguments() async throws {
        let argumentCapture = FileManager.default.temporaryDirectory.appendingPathComponent("pelican-provider-arguments-\(UUID().uuidString)")
        let script = try makeShellScript(contents: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'codex-cli 9.9.9\\n'
          exit 0
        fi
        printf '%s\\n' "$@" > "\(argumentCapture.path)"
        printf '%s\\n' '{"type":"thread.started"}'
        printf '%s\\n' '{"type":"turn.started"}'
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"<svg/>"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}'
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: argumentCapture)
        }

        let provider = CodexProvider(executableURL: script, timeout: 1)
        let request = GenerationRequest(providerID: .codex, model: "fixture-codex-model", prompt: "Return only a fixture SVG", reasoning: "high")
        let profileValue = await provider.executionProfile(for: request)
        let profile = try #require(profileValue)
        let result = try await provider.generate(request)
        let arguments = try String(contentsOf: argumentCapture, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let disabledFeatures = arguments.indices.compactMap { index -> String? in
            guard arguments[index] == "--disable", arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        #expect(profile.hasSuffix(";cli-version=codex-cli 9.9.9"))
        #expect(profile.contains("browser-use=disabled"))
        #expect(profile.contains("computer-use=disabled"))
        #expect(profile.contains("image-generation=disabled"))
        #expect(result.executionProfile == profile)
        #expect(result.returnedModel == nil)
        #expect(disabledFeatures == ["hooks", "plugins", "apps", "memories", "multi_agent", "shell_tool", "unified_exec", "browser_use", "computer_use", "image_generation"])
        #expect(arguments.contains("--strict-config"))
        #expect(arguments.contains("--ignore-user-config"))
        #expect(arguments.contains("--ignore-rules"))
        #expect(arguments.contains("--ephemeral"))
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("--json"))
        #expect(arguments.contains("--sandbox"))
        #expect(arguments.contains("read-only"))
        #expect(arguments.contains(request.prompt))
        #expect(!arguments.contains("--search"))
    }

    @Test
    func codexExecutionProfileIsBoundedAndReportsUnknownWhenVersionFails() async throws {
        let script = try makeShellScript(contents: """
        #!/bin/sh
        exec /bin/sleep 15
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let provider = CodexProvider(executableURL: script, timeout: 0.1)
        let startedAt = Date()
        let profileValue = await provider.executionProfile(for: GenerationRequest(providerID: .codex))
        let profile = try #require(profileValue)

        #expect(Date().timeIntervalSince(startedAt) < 1)
        #expect(profile.hasSuffix(";cli-version=unknown"))
    }

    @Test
    func codexProviderCancellationTerminatesForwardingChildProcess() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("pelican-provider-cancel-\(UUID().uuidString).command")
        try """
        #!/usr/bin/env node
        if (process.argv[2] === '--version') {
          process.stdout.write('codex-cli test\\n');
          process.exit(0);
        }
        const { spawn } = require('child_process');
        const child = spawn('/bin/sleep', ['15'], { stdio: 'ignore' });
        process.on('SIGTERM', () => child.kill('SIGTERM'));
        child.on('exit', (code, signal) => process.exit(signal ? 143 : (code ?? 1)));
        require('fs').writeFileSync(__filename + '.started', '1');
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let marker = URL(fileURLWithPath: script.path + ".started")
        defer { try? FileManager.default.removeItem(at: script); try? FileManager.default.removeItem(at: marker) }

        let provider = CodexProvider(executableURL: script, timeout: 30)
        let task = Task { try await provider.generate(GenerationRequest(providerID: .codex)) }
        defer { task.cancel() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "cancelled")
            #expect(failure.status == .cancelled)
            #expect(failure.executionProfile?.hasSuffix(";cli-version=codex-cli test") == true)
        }
    }

    @Test
    func codexProviderDoesNotLaunchAfterCancellation() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("pelican-provider-started-\(UUID().uuidString)")
        let script = try makeShellScript(contents: """
        #!/bin/sh
        : > "\(marker.path)"
        exec /bin/sleep 15
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: marker)
        }

        let provider = CodexProvider(executableURL: script, timeout: 1)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await provider.generate(GenerationRequest(providerID: .codex))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let failure as ProviderFailure {
            #expect(failure.type == "cancelled")
            #expect(failure.status == .cancelled)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    private func assertCodexFailure(_ raw: String, type: String) {
        do {
            _ = try CodexProvider.parseJSONL(raw)
            Issue.record("Expected a ProviderFailure")
        } catch let failure as ProviderFailure {
            #expect(failure.type == type)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(status: Int, body: String) -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
    }

    private func makeShellScript(contents: String) throws -> URL {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("pelican-provider-\(UUID().uuidString).command")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}

private func bodyData(from stream: InputStream?) -> Data? {
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

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            Issue.record("Missing URLProtocol handler")
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private let completedResponse = """
{"id":"resp_123","model":"gpt-6-astra-2026-09-15","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<svg/>\\n"}]}],"usage":{"input_tokens":11,"output_tokens":17,"total_tokens":28,"output_tokens_details":{"reasoning_tokens":3}}}
"""
