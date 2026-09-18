import Foundation

enum ProviderHTTPError: Error {
    case cancelled
    case timedOut
    case network
    case invalidHTTPResponse
}

struct ProviderHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

/// The native API adapters share only transport safeguards. Protocol payloads and
/// response semantics deliberately remain in their provider-specific files.
enum ProviderHTTP {
    static let timeout: TimeInterval = 120

    static func postJSON(
        to endpoint: URL,
        headers: [String: String],
        body: Data,
        session: URLSession) async throws -> ProviderHTTPResponse
    {
        guard !Task.isCancelled else { throw ProviderHTTPError.cancelled }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body

        do {
            return try await withThrowingTaskGroup(of: ProviderHTTPResponse.self) { group in
                group.addTask {
                    let (data, response) = try await session.data(for: request, delegate: RedirectRejectingDelegate())
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ProviderHTTPError.invalidHTTPResponse
                    }
                    return ProviderHTTPResponse(data: data, response: httpResponse)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw ProviderHTTPError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw ProviderHTTPError.network
                }
                return result
            }
        } catch is CancellationError {
            throw ProviderHTTPError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw ProviderHTTPError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw ProviderHTTPError.timedOut
        } catch let error as ProviderHTTPError {
            throw error
        } catch {
            throw ProviderHTTPError.network
        }
    }

    static func transportFailure(_ error: Error, provider: String, profile: String) -> ProviderFailure {
        switch error {
        case ProviderHTTPError.cancelled, is CancellationError:
            return ProviderFailure(type: "cancelled", message: "\(provider) request was cancelled.", status: .cancelled, executionProfile: profile)
        case ProviderHTTPError.timedOut:
            return ProviderFailure(type: "request_timeout", message: "\(provider) did not complete within 120 seconds.", executionProfile: profile)
        case ProviderHTTPError.invalidHTTPResponse:
            return ProviderFailure(type: "invalid_http_response", message: "\(provider) did not return an HTTP response.", executionProfile: profile)
        default:
            return ProviderFailure(type: "network_error", message: "Could not connect to \(provider).", executionProfile: profile)
        }
    }

    static func httpFailure(
        provider: String,
        statusCode: Int,
        rawResponse: String,
        apiKey: String,
        profile: String,
        returnedModel: String? = nil,
        usage: TokenUsage = .init()) -> ProviderFailure
    {
        let limited = statusCode == 429
        return ProviderFailure(
            type: limited ? "rate_limited" : "http_\(statusCode)",
            message: limited ? "\(provider) quota or rate limited." : "\(provider) request failed (HTTP \(statusCode)).",
            rawResponse: redacted(rawResponse, apiKey: apiKey, statusCode: statusCode),
            status: limited ? .budgetLimited : .apiError,
            returnedModel: returnedModel,
            usage: usage,
            executionProfile: profile)
    }

    /// Successful model output is retained verbatim except for the configured
    /// credential itself. Broad token-shaped redaction belongs only to errors:
    /// generated SVG identifiers can legitimately resemble API-key prefixes.
    static func successfulRaw(_ body: String, apiKey: String) -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return body }
        return body.replacingOccurrences(of: key, with: "[REDACTED]")
    }

    static func redacted(_ body: String, apiKey: String, statusCode: Int? = nil) -> String {
        var value = successfulRaw(body, apiKey: apiKey)
        for pattern in [
            "(?i)bearer\\s+[A-Za-z0-9._-]+",
            "(?i)(x-api-key|x-goog-api-key|api[_-]?key)\\s*[=:]\\s*[\\\"']?[^\\s,}\\\"']+",
            "(?i)\\\"(x-api-key|x-goog-api-key|api[_-]?key)\\\"\\s*:\\s*\\\"[^\\\"]*\\\"",
            "sk-[A-Za-z0-9._-]+",
            "AIza[A-Za-z0-9_-]+",
            "sess-[A-Za-z0-9._-]+",
            "eyJ[A-Za-z0-9._-]+",
        ] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: "[REDACTED]")
        }
        if value.isEmpty, let statusCode {
            return "API error response (HTTP \(statusCode), empty body)."
        }
        return value
    }
}

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

/// Tool payloads are never executed or inspected; only their presence/count matters.
struct IgnoredJSONValue: Decodable {
    init(from decoder: Decoder) throws {}
}
