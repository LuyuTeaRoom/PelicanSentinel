import Foundation
import Darwin

/// Executes a fresh Codex CLI session for each benchmark attempt.
///
/// Codex is an agent runtime, rather than the Responses API. The execution
/// profile deliberately records the isolation switches used here so callers do
/// not compare this series as though the requests had identical system context.
public final class CodexProvider: ModelProvider, @unchecked Sendable {
    public let executableURL: URL
    private let timeout: TimeInterval
    private let versionLock = NSLock()
    private var cachedCLIVersion: String?

    public init(executableURL: URL, timeout: TimeInterval = 120) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func executionProfile(for request: GenerationRequest) async -> String? {
        if let cached = versionLock.withLock({ cachedCLIVersion }) { return executionProfile(for: request, cliVersion: cached) }
        let fallbackProfile = executionProfile(for: request, cliVersion: "unknown")
        guard !Task.isCancelled,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return fallbackProfile
        }

        do {
            let output = try await run(executableURL: executableURL, arguments: ["--version"], timeout: min(timeout, 2))
            guard output.status == 0 else {
                versionLock.withLock { cachedCLIVersion = "unknown" }
                return fallbackProfile
            }
            let version = output.standardOutput
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> String? in
                    let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                .first
            let value = version ?? "unknown"
            versionLock.withLock { cachedCLIVersion = value }
            return executionProfile(for: request, cliVersion: value)
        } catch {
            versionLock.withLock { cachedCLIVersion = "unknown" }
            return fallbackProfile
        }
    }

    public func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        guard !Task.isCancelled else {
            throw ProviderFailure(type: "cancelled", message: "Codex generation was cancelled.", status: .cancelled)
        }

        let profile = await executionProfile(for: request) ?? executionProfile(for: request, cliVersion: "unknown")
        guard !Task.isCancelled else {
            throw ProviderFailure(type: "cancelled", message: "Codex generation was cancelled.", status: .cancelled, executionProfile: profile)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProviderFailure(type: "codex_not_found", message: "The Codex CLI executable was not found.", executionProfile: profile)
        }

        let sandboxDirectory: URL
        do {
            sandboxDirectory = try makeSandboxDirectory()
        } catch {
            throw ProviderFailure(type: "codex_sandbox_failed", message: "Could not create the Codex isolation directory.", executionProfile: profile)
        }
        defer { try? FileManager.default.removeItem(at: sandboxDirectory) }

        let arguments = codexArguments(for: request, sandboxDirectory: sandboxDirectory)
        let output: ProcessOutput
        do {
            output = try await run(executableURL: executableURL, arguments: arguments, timeout: timeout)
        } catch let failure as ProviderFailure {
            throw ProviderFailure(
                type: failure.type,
                message: failure.message,
                rawResponse: failure.rawResponse,
                status: failure.status,
                returnedModel: failure.returnedModel,
                usage: failure.usage,
                executionProfile: profile
            )
        } catch is CancellationError {
            throw ProviderFailure(type: "cancelled", message: "Codex generation was cancelled.", status: .cancelled, executionProfile: profile)
        } catch {
            throw ProviderFailure(type: "codex_launch_failed", message: "Could not launch the Codex CLI.", executionProfile: profile)
        }

        guard output.status == 0 else {
            throw ProviderFailure(
                type: "codex_exit_\(output.status)",
                message: "Codex CLI did not complete this generation (exit code \(output.status)).",
                rawResponse: output.standardOutput.isEmpty ? redactedCLIError(output.standardError) : output.standardOutput,
                executionProfile: profile
            )
        }

        let parsed: ParsedCodexResponse
        do {
            parsed = try Self.parseJSONL(output.standardOutput)
        } catch let failure as ProviderFailure {
            throw ProviderFailure(type: failure.type, message: failure.message, rawResponse: output.standardOutput, status: failure.status, executionProfile: profile)
        } catch {
            throw ProviderFailure(type: "codex_jsonl_invalid", message: "The Codex CLI event stream could not be validated.", rawResponse: output.standardOutput, executionProfile: profile)
        }

        return ProviderResponse(
            rawResponse: output.standardOutput,
            content: parsed.content,
            returnedModel: nil,
            usage: parsed.usage,
            executionProfile: profile
        )
    }

    /// Internal so the event boundary can be tested without invoking a model.
    /// Only the event sequence observed in the live canary is accepted.
    static func parseJSONL(_ raw: String) throws -> ParsedCodexResponse {
        let lines = raw.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            throw ProviderFailure(type: "codex_jsonl_empty", message: "The Codex CLI did not return events.")
        }

        var expected = 0
        var finalText: String?
        var usage: TokenUsage?
        let decoder = JSONDecoder()

        for line in lines {
            let event: CodexEvent
            do {
                event = try decoder.decode(CodexEvent.self, from: Data(line.utf8))
            } catch {
                throw ProviderFailure(type: "codex_jsonl_invalid", message: "The Codex CLI returned a non-JSON event.")
            }

            switch (expected, event.type) {
            case (0, "thread.started"):
                guard event.item == nil, event.usage == nil else {
                    throw ProviderFailure(type: "codex_event_rejected", message: "The Codex CLI start event violates the one-turn contract.")
                }
                expected = 1
            case (1, "turn.started"):
                guard event.item == nil, event.usage == nil else {
                    throw ProviderFailure(type: "codex_event_rejected", message: "The Codex CLI turn event violates the one-turn contract.")
                }
                expected = 2
            case (2, "item.completed"):
                guard let item = event.item, item.type == "agent_message",
                      let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      event.usage == nil else {
                    throw ProviderFailure(type: "codex_activity_rejected", message: "The Codex CLI used a tool, failed, or emitted unknown activity in the first turn.")
                }
                finalText = text
                expected = 3
            case (3, "turn.completed"):
                guard event.item == nil, let reportedUsage = event.usage else {
                    throw ProviderFailure(type: "codex_event_rejected", message: "The Codex CLI did not provide a verifiable completion event.")
                }
                usage = reportedUsage.tokenUsage
                expected = 4
            default:
                throw ProviderFailure(type: "codex_activity_rejected", message: "The Codex CLI used a tool, emitted multiple turns, or produced unknown activity.")
            }
        }

        guard expected == 4, let finalText, let usage else {
            throw ProviderFailure(type: "codex_event_rejected", message: "The Codex CLI did not complete the single first response.")
        }
        return ParsedCodexResponse(content: finalText, usage: usage)
    }

    private func executionProfile(for request: GenerationRequest, cliVersion: String) -> String {
        "codex-cli;fresh-session;ephemeral;isolated-best-effort;user-config=ignored;execpolicy-rules=ignored;hooks=disabled;plugins=disabled;apps=disabled;memories=disabled;multi-agent=disabled;shell-tool=disabled;unified-exec=disabled;browser-use=disabled;computer-use=disabled;image-generation=disabled;host-skill-discovery=skipped;project-doc-max-bytes=0;sandbox=read-only;reasoning=\(request.reasoning);jsonl=whitelist;output-limit=unavailable;cli-version=\(cliVersion)"
    }

    private func codexArguments(for request: GenerationRequest, sandboxDirectory: URL) -> [String] {
        [
            "exec", "--strict-config", "--ignore-user-config", "--ignore-rules",
            "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
            "--disable", "memories", "--disable", "multi_agent", "--disable", "shell_tool",
            "--disable", "unified_exec", "--disable", "browser_use", "--disable", "computer_use",
            "--disable", "image_generation", "--enable", "skip_host_skill_discovery",
            "-c", "project_doc_max_bytes=0", "-c", "suppress_unstable_features_warning=true",
            "-c", "model_reasoning_effort=\(tomlQuoted(request.reasoning))",
            "--model", request.model, "--sandbox", "read-only", "--ephemeral",
            "--skip-git-repo-check", "--json", "--color", "never", "--cd", sandboxDirectory.path,
            request.prompt
        ]
    }

    private func tomlQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func makeSandboxDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PelicanSentinel-Codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        let preferredPath = [
            executableURL.deletingLastPathComponent().path,
            NSHomeDirectory() + "/.local/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ].joined(separator: ":")
        environment["PATH"] = [preferredPath, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        let termination = ProcessTermination()

        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            do {
                let result = try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
                    group.addTask { try await Self.capture(process, termination: termination) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                        guard termination.requestTimeout() else { throw CancellationError() }
                        Self.stop(process)
                        throw Self.timeoutFailure()
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw ProviderFailure(type: "codex_launch_failed", message: "Could not launch the Codex CLI.")
                    }
                    return result
                }
                switch termination.state {
                case .timedOut:
                    throw Self.timeoutFailure()
                case .cancelled:
                    throw CancellationError()
                case .pending, .completed:
                    break
                }
                try Task.checkCancellation()
                return result
            } catch {
                switch termination.state {
                case .timedOut:
                    throw Self.timeoutFailure()
                case .cancelled:
                    throw CancellationError()
                case .pending, .completed:
                    throw error
                }
            }
        }, onCancel: {
            if termination.requestCancellation() {
                Self.stop(process)
            }
        })
    }

    private static func capture(_ process: Process, termination: ProcessTermination) async throws -> ProcessOutput {
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputCollector = DataCollector()
        let errorCollector = DataCollector()
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { outputCollector.append(data) }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errorCollector.append(data) }
        }
        process.standardOutput = standardOutput
        process.standardError = standardError

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completedProcess in
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil
                outputCollector.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
                errorCollector.append(standardError.fileHandleForReading.readDataToEndOfFile())
                termination.complete()
                continuation.resume(returning: ProcessOutput(
                    status: completedProcess.terminationStatus,
                    standardOutput: outputCollector.string,
                    standardError: errorCollector.string
                ))
            }
            do {
                try termination.start { try process.run() }
            } catch {
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ProviderFailure(type: "codex_launch_failed", message: "Could not launch the Codex CLI."))
            }
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning, pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    private static func timeoutFailure() -> ProviderFailure {
        ProviderFailure(type: "codex_timeout", message: "The Codex CLI did not complete within the time limit.")
    }

    private func redactedCLIError(_ standardError: String) -> String? {
        guard !standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Codex CLI error output was redacted."
    }
}

/// Executes one explicit OpenAI Responses API request without prior context or tools.
public final class OpenAIProvider: ModelProvider, @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = URL(string: "https://api.openai.com/v1/responses")!
    }

    public func executionProfile(for request: GenerationRequest) async -> String? {
        responseExecutionProfile(for: request)
    }

    public func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        let profile = responseExecutionProfile(for: request)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ProviderFailure(type: "missing_api_key", message: "OpenAI API key is not configured.", executionProfile: profile)
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(ResponsesRequest(
                model: request.model,
                input: request.prompt,
                reasoning: request.reasoning == "default" ? nil : .init(effort: request.reasoning),
                maxOutputTokens: request.outputLimit,
                store: false
            ))
        } catch {
            throw ProviderFailure(type: "request_encoding_failed", message: "Could not construct the OpenAI request.", executionProfile: profile)
        }

        let result: ProviderHTTPResponse
        do {
            result = try await ProviderHTTP.postJSON(
                to: endpoint,
                headers: ["Authorization": "Bearer \(key)"],
                body: body,
                session: session)
        } catch {
            throw ProviderHTTP.transportFailure(error, provider: "OpenAI API", profile: profile)
        }

        let rawResponse = String(decoding: result.data, as: UTF8.self)
        let responseMetadata = try? JSONDecoder().decode(ResponsesResponse.self, from: result.data)
        guard (200...299).contains(result.response.statusCode) else {
            throw ProviderHTTP.httpFailure(
                provider: "OpenAI API",
                statusCode: result.response.statusCode,
                rawResponse: rawResponse,
                apiKey: key,
                profile: profile,
                returnedModel: responseMetadata?.model,
                usage: responseMetadata?.usage?.tokenUsage ?? .init())
        }

        let decoded: ResponsesResponse
        do {
            decoded = try JSONDecoder().decode(ResponsesResponse.self, from: result.data)
        } catch {
            throw ProviderFailure(type: "response_decode_failed", message: "OpenAI returned an unreadable response.", rawResponse: ProviderHTTP.redacted(rawResponse, apiKey: key), executionProfile: profile)
        }

        guard decoded.status == "completed", decoded.error == nil, decoded.incompleteDetails == nil else {
            let limited = decoded.incompleteDetails?.reason == "max_output_tokens"
            throw ProviderFailure(
                type: limited ? "output_truncated" : "response_not_completed",
                message: limited ? "OpenAI stopped at the output limit." : "OpenAI did not complete the response.",
                rawResponse: ProviderHTTP.redacted(rawResponse, apiKey: key),
                status: limited ? .outputTruncated : .apiError,
                returnedModel: decoded.model,
                usage: decoded.usage?.tokenUsage ?? .init(),
                executionProfile: profile
            )
        }

        let content = decoded.output?
            .filter { $0.type == "message" && $0.role == "assistant" }
            .flatMap({ $0.content ?? [] })
            .compactMap { $0.type == "output_text" ? $0.text : nil }
            .joined() ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderFailure(
                type: "empty_response",
                message: "OpenAI did not return text.",
                rawResponse: ProviderHTTP.redacted(rawResponse, apiKey: key),
                status: .emptyResponse,
                returnedModel: decoded.model,
                usage: decoded.usage?.tokenUsage ?? .init(),
                executionProfile: profile
            )
        }

        return ProviderResponse(
            rawResponse: ProviderHTTP.successfulRaw(rawResponse, apiKey: key),
            content: content,
            returnedModel: decoded.model,
            usage: decoded.usage?.tokenUsage ?? .init(),
            executionProfile: profile
        )
    }

    private func responseExecutionProfile(for request: GenerationRequest) -> String {
        "openai-responses-v1;no-context;no-tools;store=false;reasoning=\(request.reasoning);max-output-tokens=\(request.outputLimit)"
    }

}

struct ParsedCodexResponse: Sendable {
    let content: String
    let usage: TokenUsage
}

private struct ProcessOutput: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

private final class ProcessTermination: @unchecked Sendable {
    enum State {
        case pending, completed, cancelled, timedOut
    }

    private let lock = NSLock()
    private var currentState: State = .pending

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    func start(_ operation: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = currentState else { throw CancellationError() }
        try operation()
    }

    func complete() {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = currentState else { return }
        currentState = .completed
    }

    func requestCancellation() -> Bool {
        request(.cancelled)
    }

    func requestTimeout() -> Bool {
        request(.timedOut)
    }

    private func request(_ state: State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = currentState else { return false }
        currentState = state
        return true
    }
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ value: Data) {
        guard !value.isEmpty else { return }
        lock.lock()
        data.append(value)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct CodexEvent: Decodable {
    let type: String
    let item: CodexItem?
    let usage: CodexUsage?
}

private struct CodexItem: Decodable {
    let type: String
    let text: String?
}

private struct CodexUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }

    var tokenUsage: TokenUsage {
        let countedTokens = [inputTokens, outputTokens].compactMap { $0 }
        return TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningOutputTokens,
            totalTokens: countedTokens.isEmpty ? nil : countedTokens.reduce(0, +)
        )
    }
}

private struct ResponsesRequest: Encodable {
    struct Reasoning: Encodable { let effort: String }
    let model: String
    let input: String
    let reasoning: Reasoning?
    let maxOutputTokens: Int
    let store: Bool

    enum CodingKeys: String, CodingKey {
        case model, input, reasoning, store
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct ResponsesResponse: Decodable {
    struct Output: Decodable {
        let type: String?
        let role: String?
        let content: [Content]?
    }
    struct Content: Decodable {
        let type: String?
        let text: String?
    }
    struct Usage: Decodable {
        struct OutputDetails: Decodable {
            let reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }
        let inputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
        let outputDetails: OutputDetails?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
            case outputDetails = "output_tokens_details"
        }

        var tokenUsage: TokenUsage {
            TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens, reasoningTokens: outputDetails?.reasoningTokens, totalTokens: totalTokens)
        }
    }
    struct ErrorDetails: Decodable { let code: String? }
    struct IncompleteDetails: Decodable { let reason: String? }

    let model: String?
    let status: String?
    let output: [Output]?
    let usage: Usage?
    let error: ErrorDetails?
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case model, status, output, usage, error
        case incompleteDetails = "incomplete_details"
    }
}
