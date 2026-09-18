import SwiftUI
import AppKit
import PelicanCore

private let accent = Color(red: 0.78, green: 0.34, blue: 0.14)
private let ink = Color.primary

private func dateTime(_ date: Date, language: AppLanguage) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(language.locale))
}

private func time(_ date: Date, language: AppLanguage) -> String {
    date.formatted(.dateTime.hour().minute().locale(language.locale))
}

private func intervalTitle(_ hours: Int, language: AppLanguage) -> String {
    language.choose("每 \(hours) 小时", "Every \(hours) hour\(hours == 1 ? "" : "s")")
}

private func recordModelName(_ record: ResultRecord, language: AppLanguage) -> String {
    let requested = record.requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if !requested.isEmpty { return requested }
    let display = record.modelDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return display.isEmpty ? language.choose("未知模型", "Unknown model") : display
}

private extension ProviderID {
    func credentialPrompt(in language: AppLanguage) -> String {
        switch self {
        case .codex: return "Codex CLI"
        case .openai: return language.choose("OpenAI API 密钥", "OpenAI API key")
        case .claude: return language.choose("Anthropic API 密钥", "Anthropic API key")
        case .gemini: return language.choose("Google AI Studio API 密钥", "Google AI Studio API key")
        case .compatible: return language.choose("API 密钥（本地服务器可选）", "API key (optional for local servers)")
        }
    }
}

private extension TokenLimitField {
    var displayTitle: String {
        switch self {
        case .maxTokens: return "max_tokens"
        case .maxCompletionTokens: return "max_completion_tokens"
        }
    }
}

struct SentinelMenu: View {
    @ObservedObject var model: AppModel
    private var language: AppLanguage { model.settings.language }
    private var providerShortTitle: String { model.settings.provider == .compatible ? model.l("兼容", "Compatible") : model.settings.provider.shortTitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppIdentity.name.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.8).foregroundStyle(ink)
                    Text(model.l("留下一张，此刻的鹈鹕", "Now，Plican Check")).font(.system(size: 19, weight: .semibold)).foregroundStyle(ink)
                }
                Spacer()
                BrandLogo(width: 44, language: language).accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                Circle().fill(model.generating ? accent : Color.secondary.opacity(0.55)).frame(width: 5, height: 5)
                Text(model.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(); Text(providerShortTitle).font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 4).background(ink.opacity(0.06), in: Capsule())
            }
            latest
            if !model.unreadableHistory.isEmpty {
                HStack {
                    Text(model.l("\(model.unreadableHistory.count) 条历史记录无法读取；原件已保留", "\(model.unreadableHistory.count) unreadable history item(s); originals kept")).font(.system(size: 10)).foregroundStyle(.orange)
                    Spacer(); Button(model.l("打开文件夹", "Open folder")) { model.openHistory() }.font(.system(size: 10))
                }.help(model.unreadableHistory.joined(separator: "\n"))
            }
            HStack {
                Text(model.l("最近四次请求", "Recent four requests")).font(.system(size: 12, weight: .semibold))
                Spacer(); Text("\(providerShortTitle) · \(model.l("首次响应", "First responses"))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.recent.isEmpty {
                Text(model.l("你的第一条响应会留在这里。\n固定提示词 · 原始 SVG · 本地保留 30 天", "Your first response will stay here.\nFixed prompt · Original SVG · Kept locally for 30 days"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                VStack(spacing: 6) { ForEach(model.recent) { record in historyRow(record) } }
            }
            if let pending = model.settings.pendingScheduledAt {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.l("等待确认：", "Ready for confirmation: "))\(dateTime(pending, language: language))").font(.system(size: 11))
                    HStack { Button(model.l("生成", "Generate")) { model.generate(scheduledAt: pending) }.buttonStyle(.borderedProminent).tint(accent); Button(model.l("稍后", "Later")) { model.skip() }; Spacer() }
                }.padding(10).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            if model.generating {
                HStack { ProgressView().controlSize(.small); Text(model.l("正在等待首次响应…", "Waiting for the first response…")).font(.system(size: 12)); Spacer(); Button(model.l("取消", "Cancel")) { model.cancel() } }
            } else {
                Button { model.generate(); if model.needsSettings { showSettings() } } label: { Label(model.l("立即生成", "Generate now"), systemImage: "plus").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 5) }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut("g", modifiers: .command).disabled(model.processingLocalImages || model.shuttingDown)
            }
            HStack {
                Menu { ForEach([4,2,1], id: \.self) { hour in Button(intervalTitle(hour, language: language) + (model.settings.intervalHours == hour ? " ✓" : "")) { model.setInterval(hour) } } } label: { Text(intervalTitle(model.settings.intervalHours, language: language)) }
                Menu { ForEach(GenerationMode.allCases) { mode in Button(mode.title(in: language) + (model.settings.mode == mode ? " ✓" : "")) { model.setMode(mode) } } } label: { Text(model.settings.mode.title(in: language)) }
            }.font(.system(size: 11))
            HStack {
                Text("\(model.l("下次 ", "Next "))\(time(model.settings.nextScheduledAt, language: language))").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(); Button(model.l("设置…", "Settings…")) { showSettings() }.buttonStyle(.plain); Text("·").foregroundStyle(.tertiary); Button(model.l("退出", "Quit")) { NSApp.terminate(nil) }.buttonStyle(.plain)
            }.font(.system(size: 11))
            if let message = model.message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(3) }
        }
        .padding(20).frame(width: 400).background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.needsSettings) { if $0 { showSettings() } }
    }
    private func showSettings() { SettingsWindow.shared.show(model: model); model.needsSettings = false }
    private var latest: some View {
        let record = model.displayedRecord
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.white)
                if let record, let image = model.image(for: record) {
                    Image(nsImage: image).resizable().scaledToFit().padding(4)
                } else if let record, record.status != .success {
                    VStack(spacing: 12) {
                        Image(systemName: record.status == .skippedByUser ? "forward.end" : "exclamationmark.triangle").font(.system(size: 30))
                        Text(model.l("这次没有生成图片", "No image from this request")).font(.system(size: 13, weight: .medium))
                        Text(model.recordMessage(record)).font(.system(size: 11)).multilineTextAlignment(.center).lineLimit(4)
                    }.foregroundStyle(Color.black.opacity(0.6)).padding(18)
                } else {
                    VStack(spacing: 12) {
                        BrandLogo(width: 72, language: language).opacity(0.65)
                        Text(record == nil ? model.l("第一张，等待开始", "First one, waiting to begin") : model.rebuildingPreviewID == record?.id ? model.l("正在准备图片预览", "Preparing image preview") : model.l("预览生成失败，原始 SVG 已保留", "Preview failed; original SVG preserved"))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.black.opacity(0.6))
                    }
                }
            }.frame(height: 210).overlay(RoundedRectangle(cornerRadius: 12).stroke(ink.opacity(0.08), lineWidth: 1))
                .accessibilityLabel(model.l("所选时间点的鹈鹕图", "Pelican at the selected time"))
            HStack(alignment: .top) {
                Text(record.map { recordModelName($0, language: language) } ?? model.configuration.model).font(.system(size: 11, weight: .semibold)).lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer()
                if let record { Text(dateTime(record.startedAt, language: language)).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                else { Text(model.l("暂无成功结果", "No successful result yet")).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            }
            if let note = model.displayedConfigurationNote { Text(note).font(.system(size: 10)).foregroundStyle(.secondary) }
            if let record, record.status == .success {
                if let error = record.imageExportError {
                    Text(model.l("图片保存失败：", "Image save failed: ") + error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).help(error)
                }
                if let error = record.annotationError {
                    Text(model.l("底部标注未完成，原始 SVG 已保留。", "Footer labeling failed; original SVG preserved.")).font(.system(size: 10)).foregroundStyle(.orange).help(error)
                }
                HStack {
                    if model.image(for: record) == nil {
                        Button(model.l("重新生成预览", "Rebuild preview")) { model.retryPreview(record) }
                            .accessibilityIdentifier("image.retryPreview." + record.id.uuidString)
                    }
                    if record.imageExportError != nil || record.annotationError != nil || record.savedSVGPath == nil || (record.savedImagePath == nil && model.image(for: record) != nil) {
                        Button(model.l("重新保存本图", "Save this image again")) { model.retrySave(record) }
                            .accessibilityIdentifier("image.retrySave." + record.id.uuidString)
                    }
                    if model.localWorkRecordID == record.id { ProgressView().controlSize(.small) }
                    Spacer()
                }.font(.system(size: 11)).disabled(model.generating || model.processingLocalImages || model.shuttingDown)
            }
        }
    }
    private func historyRow(_ record: ResultRecord) -> some View {
        HStack(spacing: 0) {
            Button { model.selectRecord(record) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color.white)
                        if let image = model.image(for: record) { Image(nsImage: image).resizable().scaledToFit().padding(2) }
                        else { Image(systemName: record.status == .success ? "doc.richtext" : record.status == .skippedByUser ? "forward.end" : "exclamationmark.triangle").foregroundStyle(Color.black.opacity(0.5)) }
                    }.frame(width: 67, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dateTime(record.startedAt, language: language)).font(.system(size: 11, weight: .medium))
                        Text("\(recordModelName(record, language: language)) · \(model.recordMessage(record))").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                        if let note = model.configurationNote(for: record) { Text(note).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2) }
                        if record.imageExportError != nil { Text(model.l("图片未能保存到所选文件夹。", "Images could not be saved to the selected folder.")).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(6).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(model.l("在上方查看这次结果", "Show this result above"))
                .accessibilityIdentifier("history.select." + record.id.uuidString)
            Button { if record.status == .success { model.openResult(record) } else { model.selectRecord(record) } } label: {
                Image(systemName: record.status == .success ? "arrow.up.right" : "minus")
                    .font(.system(size: 12)).frame(width: 30, height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(record.status == .success ? model.l("在预览中打开带标注的 SVG", "Open the labeled SVG in Preview") : model.l("在上方查看这次结果", "Show this result above"))
                .accessibilityLabel(record.status == .success ? model.l("打开这次的 SVG 文件", "Open this SVG file") : model.l("查看这次的失败状态", "Show this request status"))
                .accessibilityIdentifier("history.open." + record.id.uuidString)
        }
        .background(model.displayedRecord?.id == record.id ? accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.displayedRecord?.id == record.id ? accent.opacity(0.5) : Color.clear, lineWidth: 1))
    }

}

@MainActor final class SettingsDraft: ObservableObject {
    @Published var modelID = ""
    @Published var reasoning = "default"
    @Published var outputLimitText = ""
    @Published var baseURL = ""
    @Published var tokenLimitField: TokenLimitField = .maxTokens
    @Published var apiKey = ""
    @Published var executable = ""

    var configuration: ProviderConfiguration {
        ProviderConfiguration(
            model: modelID,
            reasoning: reasoning,
            outputLimit: Int(outputLimitText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            baseURL: baseURL,
            tokenLimitField: tokenLimitField)
    }

    func reset(from model: AppModel) {
        syncConfiguration(model.configuration)
        executable = model.settings.codexExecutable
        apiKey = ""
    }

    func syncConfiguration(_ configuration: ProviderConfiguration) {
        modelID = configuration.model
        reasoning = configuration.reasoning
        outputLimitText = configuration.outputLimit == 0 ? "" : String(configuration.outputLimit)
        baseURL = configuration.baseURL
        tokenLimitField = configuration.tokenLimitField
    }
}

struct SentinelSettings: View {
    @ObservedObject var model: AppModel
    @StateObject private var draft = SettingsDraft()

    private var language: AppLanguage { model.settings.language }
    private var provider: ProviderID { model.settings.provider }
    private var descriptor: ProviderDescriptor { provider.descriptor }
    private var configurationDraftChanged: Bool { draft.configuration != model.configuration }
    private var credentialDraftChanged: Bool { !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var executableDraftChanged: Bool { provider == .codex && draft.executable != model.settings.codexExecutable }
    private var hasUnsavedChanges: Bool { configurationDraftChanged || credentialDraftChanged || executableDraftChanged }
    private var canGenerate: Bool { !model.generating && !model.processingLocalImages && !model.shuttingDown && !hasUnsavedChanges && model.isConfigured }
    private var folderChangeDisabled: Bool { model.generating || model.shuttingDown || model.processingLocalImages }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) { BrandLogo(width: 52, language: language); VStack(alignment: .leading, spacing: 3) { Text(AppIdentity.name).font(.title2.weight(.semibold)); Text(model.l("模型智能检查", "Model Intelligence Check")).font(.subheadline).foregroundStyle(.secondary) } }.padding(24)
            Form {
                Section(model.l("通用", "General")) {
                    Picker(model.l("语言", "Language"), selection: Binding(get: { model.settings.language }, set: model.setLanguage)) {
                        ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.l("鹈鹕图保存路径", "Pelican image save folder"))
                        Text(model.imageSaveDirectory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(model.l("保存的 SVG 底部由本机添加模型名称、当地完成时间和时区；菜单预览和 PNG 不加字。原始响应另存于历史记录。标注不消耗 token，保存的图片不随 30 天历史清理；明确保存失败且没有 SVG 副本的记录会暂缓清理。", "Saved SVGs include a local model, completion-time and time-zone footer. Menu previews and PNGs stay clean. Original responses remain in history. Labeling uses no tokens; saved images are not deleted with 30-day history. Failed saves with no SVG copy are kept until recovered."))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(model.l("选择文件夹", "Choose folder")) { model.chooseImageSaveDirectory() }
                                .disabled(folderChangeDisabled)
                            Button(model.l("打开文件夹", "Open folder")) { model.openImageSaveDirectory() }
                                .disabled(folderChangeDisabled)
                        }
                    }
                }
                if !model.pendingExports.isEmpty {
                    Section(model.l("待保存图片", "Images awaiting save")) {
                        Text(model.l("这些图片尚未保存成功，暂缓自动清理。重新保存会使用当前选择的文件夹，不会调用模型。", "These failed saves are kept from automatic cleanup. Retry saves to the current folder without a model request.")).font(.caption).foregroundStyle(.secondary)
                        ForEach(model.pendingExports) { record in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(dateTime(record.startedAt, language: language)).font(.caption)
                                    Text(record.providerId.shortTitle + " · " + recordModelName(record, language: language)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button(model.l("重新保存", "Retry save")) { model.retrySave(record) }.disabled(folderChangeDisabled)
                                    .accessibilityIdentifier("settings.retrySave." + record.id.uuidString)
                            }
                        }
                    }
                }
                Section(model.l("连接", "Connection")) {
                    Picker(model.l("接口", "Provider"), selection: Binding(get: { model.settings.provider }, set: selectProvider)) { ForEach(ProviderID.allCases) { Text($0.title(in: language)).tag($0) } }.disabled(model.generating)
                    TextField(model.l("模型 ID", "Model ID"), text: $draft.modelID).disabled(model.generating)
                    if !descriptor.reasoningOptions.isEmpty {
                        Picker(model.l("推理", "Reasoning"), selection: $draft.reasoning) { ForEach(descriptor.reasoningOptions, id: \.self) { Text($0).tag($0) } }.disabled(model.generating)
                    } else {
                        LabeledContent(model.l("推理", "Reasoning"), value: model.l("接口默认", "Provider default"))
                    }
                    if !descriptor.usesCLI {
                        TextField(model.l("最大输出 token 数", "Maximum output tokens"), text: $draft.outputLimitText).disabled(model.generating)
                    }
                    if descriptor.allowsCustomEndpoint {
                        TextField(model.l("基础地址", "Base URL"), text: $draft.baseURL).disabled(model.generating)
                        Picker(model.l("Token 上限字段", "Token limit field"), selection: $draft.tokenLimitField) { ForEach(TokenLimitField.allCases) { Text($0.displayTitle).tag($0) } }.disabled(model.generating)
                    }
                    Text(provider.authenticationHint(in: language)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if descriptor.usesCLI {
                        HStack { TextField(model.l("Codex CLI 路径", "Codex CLI path"), text: $draft.executable).disabled(model.generating); Button(model.l("保存路径", "Save path")) { saveExecutable() }.disabled(model.generating || !executableDraftChanged) }
                        Text(model.codexAvailable ? model.l("已找到 Codex CLI；生成时会检查登录状态。", "Codex CLI found; sign-in is checked when generating.") : model.l("未找到 Codex CLI。", "Codex CLI not found.")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        SecureField(provider.credentialPrompt(in: language), text: $draft.apiKey).disabled(model.generating)
                        HStack {
                            Button(model.l("保存 API 密钥", "Save API key")) { saveAPIKey() }.disabled(model.generating || configurationDraftChanged || draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if model.hasAPIKey { Button(model.l("移除 API 密钥", "Remove API key")) { model.deleteAPIKey() }.disabled(model.generating || configurationDraftChanged) }
                            Spacer(); Text(model.hasAPIKey ? model.l("已配置", "Configured") : model.l("未配置", "Not configured")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.l("API 密钥保存于 macOS 钥匙串，仅用于此接口。", "The API key is stored in macOS Keychain for this connection only.")).font(.caption).foregroundStyle(.secondary)
                        if configurationDraftChanged { Text(model.l("请先保存接口设置，再保存密钥。", "Save connection before saving its key.")).font(.caption).foregroundStyle(.orange) }
                    }
                    HStack {
                        Spacer(); Button(model.l("保存接口设置", "Save connection")) { saveConfiguration() }.disabled(model.generating || !configurationDraftChanged)
                    }
                    if hasUnsavedChanges { Label(model.l("接口设置有未保存的更改", "Unsaved connection changes"), systemImage: "pencil").font(.caption).foregroundStyle(.orange) }
                }
                Section(model.l("观察计划", "Observation schedule")) {
                    Picker(model.l("间隔", "Interval"), selection: Binding(get: { model.settings.intervalHours }, set: model.setInterval)) { ForEach([4,2,1], id: \.self) { Text(intervalTitle($0, language: language)).tag($0) } }
                    Picker(model.l("生成模式", "Generation mode"), selection: Binding(get: { model.settings.mode }, set: model.setMode)) { ForEach(GenerationMode.allCases) { Text($0.title(in: language)).tag($0) } }
                    HStack { LabeledContent(model.l("系统通知", "System notifications"), value: model.notificationStatus); Button(model.l("允许通知", "Allow notifications")) { model.requestNotifications() } }
                    Toggle(model.l("登录时打开", "Launch at login"), isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                    LabeledContent(model.l("下次计划", "Next scheduled"), value: dateTime(model.settings.nextScheduledAt, language: language))
                }
                Section(model.l("基准与历史", "Benchmark & history")) {
                    LabeledContent(model.l("基准", "Benchmark"), value: "Pelican Classic · v1")
                    Text(Benchmark.prompt).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(model.l("每次运行都会记录所选模型和设置。保留第一条响应，不自动修复、重试或评分。", "Each run records the chosen model and settings. Keep the first response, with no automatic repair, retry or model scoring.")).font(.caption).foregroundStyle(.secondary)
                    HStack { LabeledContent(model.l("本地历史", "Local history"), value: model.l("保留 30 天", "Keep 30 days")); Button(model.l("打开历史文件夹", "Open history folder")) { model.openHistory() } }
                }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
            HStack { Text(model.l("v0.2.3 · 已保存到本地", "v0.2.3 · Saved locally")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(model.generating ? model.l("正在生成…", "Generating…") : model.l("立即生成", "Generate now")) { model.generate() }.buttonStyle(.borderedProminent).tint(accent).disabled(!canGenerate) }.padding(20)
        }.frame(width: 580, height: 730).background(Color(nsColor: .windowBackgroundColor)).onAppear { draft.reset(from: model) }.onChange(of: model.settings.provider) { _ in draft.reset(from: model) }.onChange(of: model.settings.language) { _ in SettingsWindow.shared.updateTitle(model: model) }
    }

    private func selectProvider(_ value: ProviderID) {
        model.setProvider(value)
        draft.reset(from: model)
    }

    private func saveConfiguration() {
        guard model.saveConfiguration(draft.configuration) else { return }
        draft.syncConfiguration(model.configuration)
    }

    private func saveAPIKey() {
        guard model.saveAPIKey(draft.apiKey) else { return }
        draft.apiKey = ""
    }

    private func saveExecutable() {
        guard model.saveCodexExecutable(draft.executable) else { return }
        draft.executable = model.settings.codexExecutable
    }
}
