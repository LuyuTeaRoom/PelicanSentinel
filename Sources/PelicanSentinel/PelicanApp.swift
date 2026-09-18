import SwiftUI
import AppKit
import PelicanCore

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--self-check") || CommandLine.arguments.contains("--live-codex") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do { try await SelfCheck.run(); app.terminate(nil) }
                catch { fputs("SELF_CHECK_FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            app.run()
        } else { PelicanApplication.main() }
    }
}
struct PelicanApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    init() {
        do { let initialModel = try AppModel(); _model = StateObject(wrappedValue: initialModel); AppDelegate.model = initialModel }
        catch {
            let language = Self.savedLanguage()
            let alert = NSAlert(); alert.messageText = language.choose("无法读取 \(AppIdentity.name) 本地数据", "Could not read \(AppIdentity.name) local data")
            alert.informativeText = language.choose("请检查历史文件夹或 settings.json。现有文件未被重置。", "Check the history folder or settings.json. Existing files were not reset.")
            alert.addButton(withTitle: language.choose("打开数据文件夹", "Open data folder")); alert.addButton(withTitle: language.choose("退出", "Quit"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(AppIdentity.dataDirectory)
            }
            exit(1)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
    private static func savedLanguage() -> AppLanguage {
        let url = AppIdentity.dataDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url) else { return .chinese }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AppSettings.self, from: data).language) ?? .chinese
    }
    var body: some Scene {
        MenuBarExtra { SentinelMenu(model: model) } label: {
            Image(nsImage: AppBrand.menuBar)
                .opacity(model.generating ? 0.5 : 1)
                .help(model.statusText)
                .accessibilityLabel("\(AppIdentity.name) · \(model.statusText)")
        }.menuBarExtraStyle(.window)
    }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        if terminating { return .terminateLater }
        terminating = true
        Task { await model.prepareForTermination(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    func show(model: AppModel) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 730), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = title(for: model); window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SentinelSettings(model: model)); window.center(); self.window = window
        }
        window?.title = title(for: model)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func updateTitle(model: AppModel) { window?.title = title(for: model) }
    private func title(for model: AppModel) -> String { "\(AppIdentity.name) \(model.l("设置", "Settings"))" }
}
