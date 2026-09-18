import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    public var locale: Locale { Locale(identifier: rawValue) }

    public func choose(_ chinese: String, _ english: String) -> String {
        self == .chinese ? chinese : english
    }
}

public extension GenerationMode {
    func title(in language: AppLanguage) -> String {
        switch self {
        case .ask: return language.choose("生成前询问", "Ask before generating")
        case .automatic: return language.choose("自动生成", "Generate automatically")
        }
    }
}

public extension GenerationStatus {
    func title(in language: AppLanguage) -> String {
        switch self {
        case .success: return language.choose("已生成", "Generated")
        case .apiError: return language.choose("请求失败", "Request failed")
        case .invalidSVG: return language.choose("SVG 无效", "Invalid SVG")
        case .emptyResponse: return language.choose("响应为空", "Empty response")
        case .cancelled: return language.choose("已取消", "Cancelled")
        case .skippedByUser: return language.choose("已跳过", "Skipped")
        case .budgetLimited: return language.choose("配额或速率受限", "Quota or rate limited")
        case .generating: return language.choose("进行中", "In progress")
        case .interrupted: return language.choose("已中断；结果不确定", "Interrupted; result uncertain")
        case .blockedSVG: return language.choose("预览已阻止", "Preview blocked")
        case .storageError: return language.choose("本地保存失败", "Local save failed")
        case .outputTruncated: return language.choose("输出被截断", "Output truncated")
        }
    }
}

public extension ProviderID {
    func title(in language: AppLanguage) -> String {
        switch self {
        case .codex: return language.choose("Codex（ChatGPT 登录）", "Codex (ChatGPT sign-in)")
        case .openai: return "OpenAI API"
        case .claude: return "Claude API"
        case .gemini: return "Gemini API"
        case .compatible: return language.choose("OpenAI 兼容 API", "OpenAI-compatible API")
        }
    }

    func authenticationHint(in language: AppLanguage) -> String {
        switch self {
        case .codex:
            return language.choose("使用本机 Codex CLI 中的 ChatGPT 登录状态。请先在终端运行 codex login。", "Uses the ChatGPT sign-in in your local Codex CLI. Run codex login in Terminal first.")
        case .openai:
            return language.choose("使用 OpenAI API 密钥并单独计费。ChatGPT 订阅不包含 API 额度。", "Uses an OpenAI API key and separate API billing. ChatGPT subscriptions do not include API credits.")
        case .claude:
            return language.choose("使用 Anthropic API 密钥和 Messages API。Claude 应用订阅另行计算。", "Uses an Anthropic API key with the Messages API. Claude app subscriptions are separate.")
        case .gemini:
            return language.choose("使用 Google AI Studio API 密钥和 Gemini generateContent。Gemini 应用订阅另行计算。", "Uses a Google AI Studio API key with Gemini generateContent. Gemini app subscriptions are separate.")
        case .compatible:
            return language.choose("在你选择的基础地址使用 Chat Completions。每个地址单独保存密钥；本地服务器可能无需密钥。", "Uses Chat Completions at your chosen base URL. The key is stored separately for each address. Local servers may not require a key.")
        }
    }
}
