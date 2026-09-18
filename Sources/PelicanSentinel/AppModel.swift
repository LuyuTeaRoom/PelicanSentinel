import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement
import PelicanCore

@MainActor
final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var settings: AppSettings
    @Published var records: [ResultRecord] = []
    @Published private(set) var selectedRecordID: UUID?
    @Published private(set) var preparingHistory = false
    @Published private(set) var localWorkRecordID: UUID?
    @Published private(set) var rebuildingPreviewID: UUID?
    @Published var unreadableHistory: [String] = []
    @Published var shuttingDown = false
    @Published var generating = false
    @Published var message: String?
    @Published var hasAPIKey = false
    @Published var codexAvailable = false
    private enum NotificationState { case notChecked, allowed, denied, undelivered }
    @Published private var notificationState: NotificationState = .notChecked
    var notificationStatus: String {
        switch notificationState {
        case .notChecked: return l("尚未检查", "Not checked")
        case .allowed: return l("已允许", "Allowed")
        case .denied: return l("未允许；可在菜单栏确认", "Not allowed; confirm in the menu bar")
        case .undelivered: return l("通知未送达，请查看菜单栏", "Notification not delivered; check the menu bar")
        }
    }
    @Published var launchAtLogin = false
    @Published var needsSettings = false
    let store: ResultStore
    let service: GenerationService
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var generationTask: Task<Void, Never>?
    private var historyPresentationTask: Task<Void, Never>?
    @Published private var localRecoveryTask: Task<Void, Never>?
    private var key: String?
    let testing: Bool
    func l(_ chinese: String, _ english: String) -> String { settings.language.choose(chinese, english) }
    var imageSaveDirectory: URL { imageSaveDirectory(for: settings) }
    var processingLocalImages: Bool { preparingHistory || localWorkRecordID != nil || localRecoveryTask != nil }
    var pendingExports: [ResultRecord] { records.filter(store.needsExportRecovery) }
    private func imageSaveDirectory(for settings: AppSettings) -> URL {
        if let path = settings.imageSavePath, !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return testing ? store.root.appendingPathComponent("saved-images", isDirectory: true) : AppIdentity.defaultImageSaveDirectory
    }
    func setLanguage(_ language: AppLanguage) {
        guard language != settings.language else { return }
        var updated = settings; updated.language = language
        do {
            try store.saveSettings(updated); settings = updated; message = nil
            if !testing { registerNotifications() }
        } catch { message = l("无法保存语言设置。", "Could not save the language setting.") }
    }
    func chooseImageSaveDirectory() {
        guard !generating, !shuttingDown, !processingLocalImages else { return }
        let panel = NSOpenPanel()
        panel.title = l("鹈鹕图保存路径", "Pelican image save folder")
        panel.prompt = l("选择", "Choose")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = imageSaveDirectory
        if panel.runModal() == .OK, let url = panel.url { _ = setImageSaveDirectory(url) }
    }
    @discardableResult func setImageSaveDirectory(_ url: URL) -> Bool {
        guard !generating, !shuttingDown, !processingLocalImages, url.isFileURL else { return false }
        let directory = url.standardizedFileURL
        let probe = directory.appendingPathComponent(".pelican-write-check-" + UUID().uuidString)
        do {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try Data().write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
            var updated = settings; updated.imageSavePath = directory.path
            try store.saveSettings(updated); settings = updated
            message = l("保存路径已更新；之后生成的图片将保存到此处。", "Save folder updated for future images.")
            return true
        } catch {
            message = l("无法写入该文件夹，请选择可写的保存路径。", "Cannot write to this folder. Choose a writable save folder.")
            return false
        }
    }
    func openImageSaveDirectory() {
        do {
            try FileManager.default.createDirectory(at: imageSaveDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(imageSaveDirectory)
        } catch { message = l("无法打开图片保存文件夹。", "Could not open the image save folder.") }
    }
    func recordMessage(_ record: ResultRecord) -> String {
        if settings.language == .english { return record.errorMessage ?? record.status.title }
        switch record.errorType {
        case "thumbnail_error": return "原始 SVG 已保存，但预览图未能生成。"
        case "interrupted": return "上次运行被中断，远端结果未知；不会自动重发。"
        case "cancelled": return "已取消本地等待，远端结果未知。"
        case "unsafe_svg", "svg_too_large", "svg_too_complex": return "SVG 无法安全预览，已保留原始响应。"
        case "missing_api_key": return "请先在设置中保存此接口的 API 密钥。"
        case "codex_not_found", "codex_launch_failed": return "无法启动 Codex CLI，请检查设置中的可执行文件路径。"
        case "request_timeout", "codex_timeout": return "等待请求超时，远端结果未知；不会自动重发。"
        case "network_error": return "网络请求失败，请检查连接。"
        default:
            let title = record.status.title(in: settings.language)
            guard let detail = record.errorMessage, !detail.isEmpty, detail != record.status.title else { return title }
            return title + " · " + detail
        }
    }
    private func localizedNotice(_ notice: String) -> String {
        switch notice {
        case "Configuration not fully recorded": return l("配置记录不完整", notice)
        case "Generation settings changed": return l("生成设置已变化", notice)
        case "Returned model changed": return l("返回的模型已变化", notice)
        default: return notice
        }
    }
    private func displayError(_ error: Error) -> String {
        guard settings.language == .chinese else { return error.localizedDescription }
        guard let failure = error as? ProviderFailure else { return "操作未完成：" + error.localizedDescription }
        switch failure.type {
        case "invalid_model": return "请输入此接口支持的模型 ID。"
        case "invalid_reasoning": return "请选择受支持的推理设置。"
        case "invalid_output_limit": return "输出上限应为 1 到 131,072 token；仍受模型自身限制。"
        case "invalid_endpoint": return "请输入 API 基础地址（例如 https://example.com/v1），不要包含密钥、查询参数、/chat/completions 或 /responses。HTTP 仅支持本机地址。"
        default: return failure.status.title(in: settings.language) + "：" + failure.message
        }
    }
    var configuration: ProviderConfiguration { settings.selectedConfiguration }
    private var modelRecords: [ResultRecord] { records.filter { $0.providerId == settings.provider && $0.requestedModel == configuration.model } }
    var recent: [ResultRecord] { Array(modelRecords.prefix(4)) }
    var latest: ResultRecord? { modelRecords.first { $0.status == .success } }
    var displayedRecord: ResultRecord? {
        if let selectedRecordID, let selected = recent.first(where: { $0.id == selectedRecordID }) { return selected }
        return latest
    }
    func selectRecord(_ record: ResultRecord) {
        guard recent.contains(where: { $0.id == record.id }) else { return }
        selectedRecordID = record.id
    }
    var displayedConfigurationNote: String? {
        guard let displayedRecord else { return nil }
        return selectedRecordID == nil ? latestConfigurationNote : configurationNote(for: displayedRecord)
    }

    func configurationNote(for record: ResultRecord) -> String? {
        let previous = records.first { $0.providerId == record.providerId && $0.requestedModel == record.requestedModel && $0.startedAt < record.startedAt && $0.status != .skippedByUser }
        return record.configurationNote(comparedTo: previous).map(localizedNotice)
    }
    var latestConfigurationNote: String? {
        guard let latest else { return nil }
        if let current = try? configuration.validated(for: settings.provider), latest.requestConfiguration != current { return l("最近一张图片使用的是较早或未记录的设置。", "Last image uses earlier or unrecorded settings.") }
        guard latest.configurationKnown else { return l("配置记录不完整", "Configuration not fully recorded") }
        if let newest = modelRecords.first(where: { $0.status != .skippedByUser }), newest.configurationKnown {
            if newest.seriesID != latest.seriesID { return l("最近一张图片的生成设置不同。", "Last image uses different settings.") }
            if let model = newest.returnedModel, let previous = latest.returnedModel, model != previous { return l("最近一张图片来自不同的返回模型。", "Last image came from a different returned model.") }
        }
        return nil
    }
    var isConfigured: Bool {
        guard (try? configuration.validated(for: settings.provider)) != nil else { return false }
        if settings.provider == .codex { return codexAvailable }
        return hasAPIKey || (settings.provider == .compatible && CompatibleEndpoint.isLocal(configuration.baseURL))
    }
    var statusText: String {
        if shuttingDown { return l("正在结束当前请求…", "Finishing the current request…") }
        if generating { return l("正在生成…", "Generating…") }
        if preparingHistory { return l("正在更新历史预览…", "Updating history previews…") }
        if localWorkRecordID != nil { return l("正在处理本地图片…", "Processing local images…") }
        if !isConfigured { return settings.provider == .codex ? l("请配置 Codex CLI", "Set up Codex CLI") : l("请配置此接口", "Set up this connection") }
        if settings.pendingScheduledAt != nil { return l("等待你的确认", "Ready for your confirmation") }
        if let first = recent.first, ![.success, .skippedByUser, .cancelled].contains(first.status) { return l("上次生成未成功", "Last generation failed") }
        return l("等待下一次观察", "Waiting for the next observation")
    }
    init(root: URL? = nil, testing: Bool = false) throws {
        self.testing = testing
        let directory = root ?? AppIdentity.dataDirectory
        store = try ResultStore(root: directory); service = GenerationService(store: store)
        settings = try store.settings()
        super.init()
        try store.recoverInterrupted()
        settings = try store.reconciledSettings(settings)
        try reloadHistory()
        refreshCredentials()
        refreshCodex()
        try store.saveSettings(settings)
        if !testing {
            UNUserNotificationCenter.current().delegate = self
            registerNotifications()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tick() } }
            do { try store.prune(); try reloadHistory() } catch { message = l("部分历史记录无法读取，请检查历史文件夹。", "Some history could not be read. Check the history folder.") }
            historyPresentationTask = Task { await refreshHistoryPresentation(); tick() }
        }
    }
    func reloadHistory() throws {
        let snapshot = try store.history()
        records = snapshot.records; unreadableHistory = snapshot.unreadableFiles
        if let selectedRecordID, !recent.contains(where: { $0.id == selectedRecordID }) { self.selectedRecordID = nil }
    }
    func refreshCodex() {
        if !settings.codexExecutable.isEmpty {
            codexAvailable = FileManager.default.isExecutableFile(atPath: settings.codexExecutable)
            return
        }
        let candidates = [NSHomeDirectory() + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        if let found = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) { settings.codexExecutable = found; codexAvailable = true } else { codexAvailable = false }
    }
    @discardableResult func saveCodexExecutable(_ path: String) -> Bool {
        guard !generating, !shuttingDown else { return false }
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: value) else {
            message = l("请选择可执行的 Codex CLI 文件。", "Choose an executable Codex CLI file."); return false
        }
        var updated = settings; updated.codexExecutable = value
        do { try store.saveSettings(updated); settings = updated; codexAvailable = true; message = l("Codex CLI 路径已保存。", "Codex CLI path saved."); return true }
        catch { message = l("无法保存 Codex CLI 路径。", "Could not save the Codex CLI path."); return false }
    }
    func setProvider(_ provider: ProviderID) {
        guard !generating, !shuttingDown, provider != settings.provider else { return }
        var updated = settings; updated.provider = provider; updated.pendingScheduledAt = nil
        updated.nextScheduledAt = SchedulePolicy.reschedule(now: Date(), intervalHours: updated.intervalHours)
        do {
            try store.saveSettings(updated)
            if let pending = settings.pendingScheduledAt { removePendingNotification(pending) }
            settings = updated; selectedRecordID = nil; message = nil; refreshCredentials()
        } catch { message = l("无法保存接口选择。", "Could not save the connection selection.") }
    }
    @discardableResult func saveConfiguration(_ value: ProviderConfiguration) -> Bool {
        guard !generating, !shuttingDown else { return false }
        do {
            let valid = try value.validated(for: settings.provider)
            var updated = settings; updated.providerConfigurations[settings.provider.rawValue] = valid
            updated.pendingScheduledAt = nil
            updated.nextScheduledAt = SchedulePolicy.reschedule(now: Date(), intervalHours: updated.intervalHours)
            try store.saveSettings(updated)
            if let pending = settings.pendingScheduledAt { removePendingNotification(pending) }
            settings = updated; selectedRecordID = nil; message = l("接口设置已保存。", "Connection settings saved."); refreshCredentials()
            return true
        } catch { message = displayError(error); return false }
    }
    private func refreshCredentials() {
        key = nil; hasAPIKey = false
        guard !testing, !settings.provider.descriptor.usesCLI else { return }
        if settings.provider == .compatible && configuration.baseURL.isEmpty { return }
        do {
            let keychain = try KeychainStore.forProvider(settings.provider, configuration: configuration)
            key = try keychain.read(); hasAPIKey = !(key ?? "").isEmpty
        } catch { message = displayError(error) }
    }
    @discardableResult func saveSettings() -> Bool {
        do { try store.saveSettings(settings); return true } catch { message = l("无法保存设置，请检查存储权限。", "Could not save settings. Check storage permissions."); return false }
    }
    @discardableResult func saveAPIKey(_ value: String) -> Bool {
        guard !generating, !shuttingDown, !settings.provider.descriptor.usesCLI else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .newlines) == nil else { message = l("请输入有效的 API 密钥。", "Enter a valid API key."); return false }
        do {
            let keychain = try KeychainStore.forProvider(settings.provider, configuration: configuration)
            try keychain.save(trimmed); key = trimmed; hasAPIKey = true
            message = l("此接口的 API 密钥已保存到 macOS 钥匙串。", "API key saved in macOS Keychain for this connection."); return true
        } catch { message = displayError(error); return false }
    }
    func deleteAPIKey() {
        guard !generating, !shuttingDown, !settings.provider.descriptor.usesCLI else { return }
        do {
            try KeychainStore.forProvider(settings.provider, configuration: configuration).remove()
            key = nil; hasAPIKey = false; message = l("此接口的 API 密钥已移除。", "API key removed for this connection.")
        } catch { message = displayError(error) }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { message = l("请在系统设置的登录项中允许 Pelican Sentinel。", "Allow Pelican Sentinel in System Settings > Login Items.") }
        } catch { message = l("无法更改登录项，请检查系统设置。", "Could not change login items. Check System Settings."); launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    func tick(now: Date = Date(), providerOverride: (any ModelProvider)? = nil) {
        guard !shuttingDown, !generating, !processingLocalImages, isConfigured || providerOverride != nil else { return }
        guard let due = SchedulePolicy.consumeDue(next: settings.nextScheduledAt, now: now, intervalHours: settings.intervalHours) else { return }
        if records.contains(where: { $0.matchesSchedule(provider: settings.provider, at: due.scheduledAt) }) {
            do { settings = try store.reconciledSettings(settings, now: now); try store.saveSettings(settings) }
            catch { message = l("无法恢复计划，请检查存储权限。", "Could not restore the schedule. Check storage permissions.") }
            return
        }
        if settings.mode == .ask {
            let shouldNotify = settings.pendingScheduledAt == nil
            var updated = settings; updated.nextScheduledAt = due.next
            if shouldNotify { updated.pendingScheduledAt = due.scheduledAt }
            do { try store.saveSettings(updated); settings = updated }
            catch { message = l("无法保存计划，请检查存储权限。", "Could not save the schedule. Check storage permissions."); return }
            if shouldNotify { notify(title: l("该观察鹈鹕了", "Time for a pelican observation"), body: l("生成一张新的骑车鹈鹕 SVG？", "Generate a new SVG of a pelican riding a bicycle?"), identifier: notificationID(due.scheduledAt), category: "PELICAN_ASK") }
        } else { generate(scheduledAt: due.scheduledAt, nextScheduledAt: due.next, providerOverride: providerOverride) }
    }
    func generate(scheduledAt: Date? = nil, nextScheduledAt: Date? = nil, providerOverride: (any ModelProvider)? = nil) {
        guard !generating, !shuttingDown, !processingLocalImages else { return }
        guard isConfigured || providerOverride != nil else { message = settings.provider == .codex ? l("请在设置中选择已安装的 Codex CLI。", "Choose an installed Codex CLI in Settings.") : l("请先在设置中配置模型、接口和 API 密钥。", "Configure the model, connection and API key in Settings first."); needsSettings = true; return }
        let scheduled = scheduledAt ?? settings.pendingScheduledAt
        let snapshot = settings
        let provider: any ModelProvider
        if let providerOverride { provider = providerOverride }
        else {
            do {
                let valid = try snapshot.selectedConfiguration.validated(for: snapshot.provider)
                switch snapshot.provider {
                case .codex: provider = CodexProvider(executableURL: URL(fileURLWithPath: snapshot.codexExecutable))
                case .openai: provider = OpenAIProvider(apiKey: key ?? "")
                case .claude: provider = ClaudeProvider(apiKey: key ?? "")
                case .gemini: provider = GeminiProvider(apiKey: key ?? "")
                case .compatible: provider = try OpenAICompatibleProvider(apiKey: key ?? "", baseURL: valid.baseURL, tokenLimitField: valid.tokenLimitField)
                }
            } catch { message = displayError(error); needsSettings = true; return }
        }
        generating = true; message = nil
        generationTask = Task {
            do {
                let renderer = ThumbnailRenderer()
                var record = try await service.generate(provider: provider, settings: snapshot, scheduledAt: scheduled, beforeRequest: {
                    var updated = self.settings
                    if let nextScheduledAt, updated.nextScheduledAt == snapshot.nextScheduledAt { updated.nextScheduledAt = nextScheduledAt }
                    let pending = updated.pendingScheduledAt
                    if pending == scheduled { updated.pendingScheduledAt = nil }
                    try self.store.saveSettings(updated)
                    self.settings = updated
                    if let pending, updated.pendingScheduledAt == nil { self.removePendingNotification(pending) }
                    try self.reloadHistory()
                }, thumbnail: { try await renderer.render($0) })
                if record.status == .success { record = finalizeImages(record, settings: snapshot) }
                try store.prune(); try reloadHistory()
                message = record.status == .success ? localResultMessage(record) : recordMessage(record)
                if !shuttingDown, snapshot.mode == .automatic && scheduled != nil { notify(title: record.status == .success ? l("新鹈鹕已经就绪", "Your new pelican is ready") : l("生成未完成", "Generation did not complete"), body: record.status == .success ? l("打开菜单栏查看最新图片。", "Open the menu bar to see the latest image.") : recordMessage(record), identifier: record.id.uuidString) }
            } catch { message = l("无法保存结果，请检查存储权限。", "Could not save the result. Check storage permissions."); try? reloadHistory() }
            generating = false; generationTask = nil
        }
    }
    @discardableResult func finalizeImages(_ original: ResultRecord, settings snapshot: AppSettings, forceExport: Bool = false) -> ResultRecord {
        guard original.status == .success, forceExport || original.savedSVGPath == nil else { return original }
        var record = original
        do {
            let source = try sourceSVG(for: record)
            let exportedSVG = prepareAnnotatedSVG(source, record: &record)
            let png: Data?
            if image(for: record) != nil, let path = record.thumbnailPath, let url = store.url(for: path) {
                png = try? Data(contentsOf: url)
            } else { png = nil }
            let paths = try ImageExporter.export(svg: exportedSVG, png: png, record: record, directory: imageSaveDirectory(for: snapshot))
            record.savedImagePath = paths.png?.path; record.savedSVGPath = paths.svg.path
            record.imageExportError = nil
        } catch { record.imageExportError = error.localizedDescription }
        do { try store.save(record) }
        catch { record.imageExportError = "Could not record image export details: " + error.localizedDescription }
        return record
    }
    private func sourceSVG(for record: ResultRecord) throws -> String {
        guard let path = record.svgPath, let url = store.url(for: path) else { throw CocoaError(.fileReadNoSuchFile) }
        let source = try String(contentsOf: url, encoding: .utf8)
        try SVGValidator.validate(source)
        return source
    }
    private func prepareAnnotatedSVG(_ source: String, record: inout ResultRecord) -> String {
        do {
            let annotated = try ImageExporter.annotatedSVG(svg: source, record: record)
            record.annotatedSVGPath = try store.saveText(annotated, id: record.id, suffix: "annotated.svg")
            record.annotationError = nil
            return annotated
        } catch {
            record.annotationError = error.localizedDescription
            record.annotatedSVGPath = nil
            return source
        }
    }
    func localResultMessage(_ record: ResultRecord) -> String {
        if let error = record.imageExportError { return l("图片保存失败：", "Image save failed: ") + error }
        if record.annotationError != nil { return l("原始 SVG 已保留，底部标注未完成。", "Original SVG preserved; footer labeling failed.") }
        if image(for: record) == nil { return l("SVG 已保存，预览生成失败；可在本机重新生成预览。", "SVG saved; preview failed. You can rebuild it locally.") }
        return l("首次回复和图片已保存。", "First response and images saved.")
    }
    func retrySave(_ record: ResultRecord) { startLocalRecovery(record, exportImages: true) }
    func retryPreview(_ record: ResultRecord) { startLocalRecovery(record, exportImages: false) }
    private func startLocalRecovery(_ record: ResultRecord, exportImages: Bool) {
        guard !generating, !shuttingDown, !processingLocalImages, localRecoveryTask == nil, record.status == .success else { return }
        localRecoveryTask = Task {
            await recoverLocalResult(record.id, exportImages: exportImages)
            localRecoveryTask = nil
        }
    }
    // Reuse persisted first-response data. This path never constructs a provider.
    func recoverLocalResult(_ id: UUID, exportImages: Bool, renderer: ((String) async throws -> Data)? = nil) async {
        guard !generating, !shuttingDown, !preparingHistory, localWorkRecordID == nil else { return }
        localWorkRecordID = id
        let snapshot = settings
        defer { localWorkRecordID = nil; rebuildingPreviewID = nil }
        do {
            guard var record = try store.records().first(where: { $0.id == id }), record.status == .success else { return }
            let source = try sourceSVG(for: record)
            if !exportImages || image(for: record) == nil {
                rebuildingPreviewID = id
                do {
                    let png: Data
                    if let renderer { png = try await renderer(source) }
                    else { png = try await ThumbnailRenderer().render(source) }
                    try Task.checkCancellation()
                    guard NSImage(data: png) != nil else { throw CocoaError(.fileReadCorruptFile) }
                    record.thumbnailPath = try store.saveThumbnail(png, id: record.id)
                    record.presentationVersion = 2
                    if record.errorType == "thumbnail_error" { record.errorType = nil; record.errorMessage = nil }
                } catch is CancellationError { return }
                catch { record.errorType = "thumbnail_error"; record.errorMessage = error.localizedDescription }
                rebuildingPreviewID = nil
            }
            try Task.checkCancellation()
            if exportImages { record = finalizeImages(record, settings: snapshot, forceExport: true) }
            else {
                _ = prepareAnnotatedSVG(source, record: &record)
                try store.save(record)
            }
            try reloadHistory()
            message = exportImages ? localResultMessage(record) : (image(for: record) != nil ? l("预览已重新生成。", "Preview rebuilt.") : l("预览生成失败，原始 SVG 已保留。", "Preview failed; original SVG preserved."))
        } catch is CancellationError { return }
        catch { message = l("本地图片处理失败：", "Local image processing failed: ") + error.localizedDescription }
    }
    // Upgrade legacy PNGs independently of annotation; each source remains untouched.
    func refreshHistoryPresentation() async {
        guard !preparingHistory, localWorkRecordID == nil, localRecoveryTask == nil, !generating else { return }
        preparingHistory = true
        defer { preparingHistory = false; rebuildingPreviewID = nil }
        let legacy = records.filter { $0.status == .success && image(for: $0) == nil }
        for var record in legacy {
            do {
                try Task.checkCancellation()
                let source = try sourceSVG(for: record)
                rebuildingPreviewID = record.id
                do {
                    let png = try await ThumbnailRenderer().render(source)
                    try Task.checkCancellation()
                    record.thumbnailPath = try store.saveThumbnail(png, id: record.id)
                    record.presentationVersion = 2
                    if record.errorType == "thumbnail_error" { record.errorType = nil; record.errorMessage = nil }
                } catch is CancellationError { return }
                catch { record.errorType = "thumbnail_error"; record.errorMessage = error.localizedDescription }
                rebuildingPreviewID = nil
                _ = prepareAnnotatedSVG(source, record: &record)
                try store.save(record)
                try reloadHistory()
            } catch is CancellationError { return }
            catch { message = l("部分历史预览无法更新，原始文件已保留。", "Some history previews could not be updated. Originals preserved.") }
        }
    }
    func cancel() { generationTask?.cancel() }
    func prepareForTermination() async {
        shuttingDown = true; timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        generationTask?.cancel()
        localRecoveryTask?.cancel()
        historyPresentationTask?.cancel()
        await historyPresentationTask?.value
        historyPresentationTask = nil
        await localRecoveryTask?.value
        localRecoveryTask = nil
        for _ in 0..<50 {
            if !generating { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        do { try service.interruptActive() }
        catch { message = l("退出前未能更新记录；将在下次启动时恢复。", "Could not update the record before quitting; recovery will run on next launch.") }
    }
    func skip() {
        guard !generating, !shuttingDown, let scheduled = settings.pendingScheduledAt else { return }
        do { try service.skip(settings: settings, scheduledAt: scheduled); try reloadHistory(); message = l("已跳过本次观察，不计为模型失败。", "Skipped this observation. It is not a model failure.") } catch { message = l("无法保存跳过记录。", "Could not save the skipped observation."); return }
        clearPending(); saveSettings()
    }
    private func clearPending() {
        if let pending = settings.pendingScheduledAt { removePendingNotification(pending) }
        settings.pendingScheduledAt = nil
    }
    func removePendingNotification(_ date: Date) {
        guard !testing else { return }
        let id = notificationID(date)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
    func previewURL(for record: ResultRecord) throws -> URL? {
        guard record.status == .success else { return nil }
        var updated = try store.records().first(where: { $0.id == record.id }) ?? record
        if let path = updated.annotatedSVGPath, let url = store.url(for: path), FileManager.default.fileExists(atPath: url.path) { return url }
        let source = try sourceSVG(for: updated)
        _ = prepareAnnotatedSVG(source, record: &updated)
        try store.save(updated); try reloadHistory()
        if updated.annotationError != nil { message = l("底部标注未完成，正在打开原始 SVG。", "Footer labeling failed; opening the original SVG.") }
        return (updated.annotatedSVGPath ?? updated.svgPath).flatMap(store.url(for:))
    }
    func openResult(_ record: ResultRecord) {
        do {
            guard let url = try previewURL(for: record) else { return }
            try PreviewController.shared.open(url)
        } catch { message = l("SVG 无法安全预览，原始文件已保留。", "The SVG cannot be safely previewed. The original is preserved.") }
    }
    func image(for record: ResultRecord) -> NSImage? {
        guard record.status == .success, record.presentationVersion == 2, let path = record.thumbnailPath, let url = store.url(for: path) else { return nil }
        return NSImage(contentsOf: url)
    }
    func openHistory() { NSWorkspace.shared.open(store.root) }
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in Task { @MainActor in self?.notificationState = granted ? .allowed : .denied } }
    }
    private func registerNotifications() {
        let actions = [UNNotificationAction(identifier: "GENERATE", title: l("生成", "Generate"), options: [.foreground]), UNNotificationAction(identifier: "LATER", title: l("跳过", "Skip"), options: [])]
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "PELICAN_ASK", actions: actions, intentIdentifiers: [], options: [])])
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] status in Task { @MainActor in self?.notificationState = status.authorizationStatus == .authorized ? .allowed : .denied } }
    }
    private func notificationID(_ date: Date) -> String { "pelican.ask.\(Int(date.timeIntervalSince1970))" }
    private func notify(title: String, body: String, identifier: String, category: String = "") {
        guard !testing else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.categoryIdentifier = category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
            if error != nil { Task { @MainActor in self?.notificationState = .undelivered } }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            defer { completionHandler() }
            guard let due = settings.pendingScheduledAt, response.notification.request.identifier == notificationID(due) else { return }
            if response.actionIdentifier == "GENERATE" { generate(scheduledAt: due) }
            else if response.actionIdentifier == "LATER" { skip() }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}
