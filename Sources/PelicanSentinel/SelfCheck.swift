import AppKit
import SwiftUI
import PelicanCore

@MainActor enum SelfCheck {
    static func run() async throws {
        let args = CommandLine.arguments
        let output: URL
        if let i = args.firstIndex(of: "--output"), args.indices.contains(i+1) { output = URL(fileURLWithPath: args[i+1], isDirectory: true) }
        else { output = FileManager.default.temporaryDirectory.appendingPathComponent("PelicanSentinel-QA-\(UUID().uuidString)") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let i = args.firstIndex(of: "--render-data"), args.indices.contains(i+1) {
            let model = try AppModel(root: URL(fileURLWithPath: args[i+1]), testing: true)
            await model.refreshHistoryPresentation()
            for record in model.recent {
                model.selectRecord(record)
                try await snapshot(SentinelMenu(model: model), size: NSSize(width: 400, height: 810), to: output.appendingPathComponent("selected-\(record.id.uuidString).png"))
                if let url = try model.previewURL(for: record) {
                    let svg = try String(contentsOf: url, encoding: .utf8)
                    try await ThumbnailRenderer().render(svg).write(to: output.appendingPathComponent("svg-\(record.id.uuidString).png"))
                }
            }
            print("LIVE_HISTORY_RENDER_PASS records=\(model.records.count)")
            return
        }
        if args.contains("--live-codex") {
            let model = try AppModel(root: output.appendingPathComponent("live-data"), testing: true)
            let renderer = ThumbnailRenderer()
            let record = try await model.service.generate(provider: CodexProvider(executableURL: URL(fileURLWithPath: model.settings.codexExecutable)), settings: model.settings, thumbnail: { try await renderer.render($0) })
            model.records = try model.store.records()
            try await snapshot(SentinelMenu(model: model), size: NSSize(width: 400, height: 750), to: output.appendingPathComponent("live-menu.png"))
            print("LIVE_CODEX status=\(record.status.rawValue) thumbnail=\(record.thumbnailPath != nil) result=\(record.id.uuidString)")
            if record.status != .success { throw NSError(domain: "Live", code: 1, userInfo: [NSLocalizedDescriptionKey: record.errorMessage ?? record.status.title]) }
            return
        }
        let model = try AppModel(root: output.appendingPathComponent("qa-data-\(UUID().uuidString)"), testing: true)
        let renderer = ThumbnailRenderer()
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 400"><rect width="600" height="400" fill="#faf7f0"/><circle cx="165" cy="278" r="66" fill="none" stroke="#283e43" stroke-width="7"/><circle cx="428" cy="278" r="66" fill="none" stroke="#283e43" stroke-width="7"/><path d="M165 278 L235 178 L300 278 Z M235 178 L385 178 L300 278 M370 141 L428 278 M346 138 L391 138" fill="none" stroke="#c86940" stroke-width="8" stroke-linejoin="round"/><path d="M248 103 Q187 132 229 181 Q280 202 321 159 Q311 132 295 107 L315 80 Q325 42 347 72 L347 107 L413 112 L343 132 Q320 160 297 166" fill="#fff" stroke="#283e43" stroke-width="4"/><path d="M347 107 L413 112 L343 132 Z" fill="#dcad53"/><circle cx="342" cy="87" r="4" fill="#283e43"/><path d="M277 172 L286 226 L315 238 M313 154 L354 152" fill="none" stroke="#283e43" stroke-width="5"/><text x="300" y="367" font-size="13" text-anchor="middle" fill="#789">SELF-CHECK FIXTURE · NOT A MODEL RESULT</text></svg>
        """
        let png = try await renderer.render(svg)
        guard NSImage(data: png) != nil, png.count > 1000 else { throw NSError(domain: "QA", code: 2) }
        try png.write(to: output.appendingPathComponent("thumbnail.png"))
        for i in 0..<4 {
            var record = ResultRecord(providerId: .codex, startedAt: Date().addingTimeInterval(Double(-i) * 14400), generationMode: .ask, scheduleInterval: 4, status: .success)
            record.executionProfile = "self-check-fixture-not-model-output;cli-version=fixture"
            record.requestConfiguration = model.configuration
            record.rawResponsePath = try model.store.saveText(svg, id: record.id, suffix: "response.txt")
            record.svgPath = try model.store.saveText(svg, id: record.id, suffix: "svg")
            record.thumbnailPath = try model.store.saveThumbnail(png, id: record.id)
            record.presentationVersion = 2
            try model.store.save(record)
        }
        model.records = try model.store.records()
        for language in AppLanguage.allCases {
            model.setLanguage(language)
            model.setProvider(.codex)
            let prefix = language == .chinese ? "zh" : "en"
            try await snapshot(SentinelMenu(model: model), size: NSSize(width: 400, height: 750), to: output.appendingPathComponent("\(prefix)-menu-four-results.png"))
            for provider in ProviderID.allCases {
                model.setProvider(provider)
                if provider == .compatible { _ = model.saveConfiguration(.init(model: "your-local-model", baseURL: "http://localhost:11434/v1")) }
                try await snapshot(SentinelSettings(model: model), size: NSSize(width: 580, height: 730), to: output.appendingPathComponent("\(prefix)-settings-\(provider.rawValue).png"))
            }
        }
        // One fixture request exercises the actual app generation-to-export path without a model API.
        let fixture = ExportFixtureProvider(svg: svg)
        let flow = try AppModel(root: output.appendingPathComponent("export-flow-data"), testing: true)
        let chosen = output.appendingPathComponent("自选鹈鹕图路径", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        guard flow.setImageSaveDirectory(chosen) else { throw NSError(domain: "QA", code: 10) }
        flow.generate(providerOverride: fixture)
        for _ in 0..<200 {
            if !flow.generating { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !flow.generating, await fixture.count() == 1,
              let result = flow.records.first, result.status == .success,
              result.usage.totalTokens == 13, result.imageExportError == nil,
              let savedSVG = result.savedSVGPath, let savedPNG = result.savedImagePath,
              try String(contentsOfFile: savedSVG, encoding: .utf8).contains("Completed:"),
              let sourcePath = result.svgPath, let sourceURL = flow.store.url(for: sourcePath),
              try String(contentsOf: sourceURL, encoding: .utf8) == svg,
              NSImage(contentsOfFile: savedPNG) != nil else { throw NSError(domain: "QA", code: 11) }
        let exportedSVG = try String(contentsOfFile: savedSVG, encoding: .utf8)
        try exportedSVG.write(to: output.appendingPathComponent("annotated-export.svg"), atomically: true, encoding: .utf8)
        try await ThumbnailRenderer().render(exportedSVG).write(to: output.appendingPathComponent("annotated-svg-render.png"))
        try Data(contentsOf: URL(fileURLWithPath: savedPNG)).write(to: output.appendingPathComponent("clean-export.png"))
        guard let thumbnail = result.thumbnailPath, let thumbnailURL = flow.store.url(for: thumbnail),
              try Data(contentsOf: thumbnailURL) == Data(contentsOf: URL(fileURLWithPath: savedPNG)) else { throw NSError(domain: "QA", code: 14) }
        // Exercise selected old success, failure and migration from the prior labeled-PNG release.
        model.setProvider(.codex); model.setLanguage(.chinese)
        var old = model.records[2]
        let blueSVG = svg.replacingOccurrences(of: "#faf7f0", with: "#d7edff")
        old.svgPath = try model.store.saveText(blueSVG, id: old.id, suffix: "svg")
        old.presentationVersion = nil
        old.thumbnailPath = try model.store.saveThumbnail(Data("old labeled thumbnail placeholder".utf8), id: old.id)
        try model.store.save(old); try model.reloadHistory()
        await model.refreshHistoryPresentation()
        guard let upgraded = model.records.first(where: { $0.id == old.id }), upgraded.presentationVersion == 2,
              upgraded.annotatedSVGPath != nil, model.image(for: upgraded) != nil,
              try String(contentsOf: model.store.url(for: old.svgPath!)!) == blueSVG else { throw NSError(domain: "QA", code: 15) }
        model.selectRecord(upgraded)
        try await snapshot(SentinelMenu(model: model), size: NSSize(width: 400, height: 790), to: output.appendingPathComponent("selected-older-menu.png"))
        var failure = model.records[1]; failure.status = .apiError; failure.errorType = "request_timeout"
        try model.store.save(failure); try model.reloadHistory(); model.selectRecord(failure)
        try await snapshot(SentinelMenu(model: model), size: NSSize(width: 400, height: 790), to: output.appendingPathComponent("selected-failure-menu.png"))
        guard model.displayedRecord?.id == failure.id, try model.previewURL(for: failure) == nil else { throw NSError(domain: "QA", code: 16) }
        try await snapshot(SentinelMenu(model: flow), size: NSSize(width: 400, height: 660), to: output.appendingPathComponent("zh-export-menu.png"))
        let restored = try AppModel(root: flow.store.root, testing: true)
        guard restored.imageSaveDirectory.standardizedFileURL.path == chosen.standardizedFileURL.path, restored.records.first?.savedImagePath == savedPNG else { throw NSError(domain: "QA", code: 12) }
        // A failed destination preserves successful generation and never re-requests the provider.
        let blocked = output.appendingPathComponent("blocked-export-folder")
        try Data("existing-file".utf8).write(to: blocked)
        var failedSettings = flow.settings; failedSettings.imageSavePath = blocked.path
        var failedRecord = result; failedRecord.id = UUID(); failedRecord.savedImagePath = nil; failedRecord.savedSVGPath = nil
        failedRecord.svgPath = try flow.store.saveText(svg, id: failedRecord.id, suffix: "svg")
        failedRecord.thumbnailPath = try flow.store.saveThumbnail(png, id: failedRecord.id)
        try flow.store.save(failedRecord)
        let failed = flow.finalizeImages(failedRecord, settings: failedSettings)
        guard failed.status == .success, failed.imageExportError != nil, await fixture.count() == 1,
              try String(contentsOf: blocked) == "existing-file" else { throw NSError(domain: "QA", code: 13) }
        // Recover an export to the corrected folder without generating again.
        try flow.reloadHistory()
        for language in AppLanguage.allCases {
            flow.setLanguage(language)
            flow.selectRecord(failed)
            let prefix = language == .chinese ? "zh" : "en"
            try await snapshot(SentinelMenu(model: flow), size: NSSize(width: 400, height: 850), to: output.appendingPathComponent("\(prefix)-retry-save-menu.png"))
            try await snapshot(SentinelSettings(model: flow), size: NSSize(width: 580, height: 730), to: output.appendingPathComponent("\(prefix)-pending-exports-settings.png"))
        }
        await flow.recoverLocalResult(failed.id, exportImages: true)
        guard let recovered = flow.records.first(where: { $0.id == failed.id }), recovered.imageExportError == nil,
              recovered.savedSVGPath != nil, recovered.savedImagePath != nil,
              await fixture.count() == 1 else { throw NSError(domain: "QA", code: 17) }
        // A missing PNG no longer blocks SVG export; actual WebKit can restore it locally.
        var noPreview = result; noPreview.id = UUID(); noPreview.startedAt = Date()
        noPreview.savedImagePath = nil; noPreview.savedSVGPath = nil; noPreview.annotatedSVGPath = nil
        noPreview.thumbnailPath = nil; noPreview.presentationVersion = nil
        noPreview.errorType = "thumbnail_error"; noPreview.errorMessage = "Fixture render failure"
        noPreview.svgPath = try flow.store.saveText(svg, id: noPreview.id, suffix: "svg")
        let svgOnly = flow.finalizeImages(noPreview, settings: flow.settings)
        guard svgOnly.savedSVGPath != nil, svgOnly.savedImagePath == nil, svgOnly.imageExportError == nil else { throw NSError(domain: "QA", code: 18) }
        try flow.reloadHistory(); flow.selectRecord(svgOnly)
        for language in AppLanguage.allCases {
            flow.setLanguage(language)
            let prefix = language == .chinese ? "zh" : "en"
            try await snapshot(SentinelMenu(model: flow), size: NSSize(width: 400, height: 850), to: output.appendingPathComponent("\(prefix)-preview-failure-menu.png"))
        }
        await flow.recoverLocalResult(svgOnly.id, exportImages: false)
        guard let rebuilt = flow.records.first(where: { $0.id == svgOnly.id }), rebuilt.errorType == nil,
              flow.image(for: rebuilt) != nil, await fixture.count() == 1 else { throw NSError(domain: "QA", code: 19) }
        flow.setLanguage(.chinese)
        try await snapshot(SentinelMenu(model: flow), size: NSSize(width: 400, height: 850), to: output.appendingPathComponent("preview-rebuilt-menu.png"))
        let cmSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10cm\" height=\"10cm\"><circle cx=\"180\" cy=\"280\" r=\"50\" fill=\"#db6229\"/></svg>"
        let cmAnnotated = try ImageExporter.annotatedSVG(svg: cmSVG, record: result)
        try cmAnnotated.write(to: output.appendingPathComponent("centimeter-footer.svg"), atomically: true, encoding: .utf8)
        try await ThumbnailRenderer().render(cmAnnotated).write(to: output.appendingPathComponent("centimeter-footer.png"))
        try "PASS: failed export recovered to current folder; original ID and fixture request count retained; missing PNG still saves SVG; actual WebKit rebuild restores preview; cm geometry and SVG footer rendered.\n".write(to: output.appendingPathComponent("local-recovery.txt"), atomically: true, encoding: .utf8)
        try "PASS: actual AppModel fixture generation made one request; custom folder contains annotated SVG and clean PNG; original response SVG and menu PNG unchanged; token total stays 13; selected history success/failure switches top; legacy thumbnail rebuilt; restart restores path; export failure preserves success and makes no extra request.\n".write(to: output.appendingPathComponent("export-flow.txt"), atomically: true, encoding: .utf8)
        var settings = model.settings; settings.intervalHours = 1; try model.store.saveSettings(settings)
        guard try model.store.settings().intervalHours == 1 else { throw NSError(domain: "QA", code: 3) }
        let temporaryKeychain = KeychainStore(service: "com.pelicansentinel.selfcheck.\(UUID().uuidString)")
        try temporaryKeychain.save("selfcheck-not-a-real-api-key")
        guard try temporaryKeychain.read() == "selfcheck-not-a-real-api-key" else { throw NSError(domain: "QA", code: 4) }
        try temporaryKeychain.remove()
        guard try temporaryKeychain.read() == nil else { throw NSError(domain: "QA", code: 5) }
        let keychainRun = UUID().uuidString
        let credentialScopes: [(ProviderID, ProviderConfiguration)] = [
            (.openai, .defaults(for: .openai)), (.claude, .defaults(for: .claude)), (.gemini, .defaults(for: .gemini)),
            (.compatible, .init(model: "fixture", baseURL: "https://one.example/v1")),
            (.compatible, .init(model: "fixture", baseURL: "https://two.example/v1"))
        ]
        let scopedStores = try credentialScopes.map { provider, configuration -> KeychainStore in
            var store = try KeychainStore.forProvider(provider, configuration: configuration)
            store.service += ".selfcheck.\(keychainRun)"
            return store
        }
        defer { for store in scopedStores { try? store.remove() } }
        for (index, store) in scopedStores.enumerated() { try store.save("fixture-key-\(index)") }
        for (index, store) in scopedStores.enumerated() {
            guard try store.read() == "fixture-key-\(index)" else { throw NSError(domain: "QA", code: 8) }
        }
        for store in scopedStores { try store.remove() }
        for store in scopedStores { guard try store.read() == nil else { throw NSError(domain: "QA", code: 9) } }
        try "PASS: WKWebView SVG→PNG, actual SwiftUI menu/settings render, four results, provider separation, settings persistence, temporary Keychain write/read/delete.\nNotification authorization, login startup and real sleep are OS-interactive checks, not simulated successes.\n".write(to: output.appendingPathComponent("self-check.txt"), atomically: true, encoding: .utf8)
        print("SELF_CHECK_PASS output=\(output.path)")
    }
    static func snapshot<V: View>(_ view: V, size: NSSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "QA", code: 6) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "QA", code: 7) }
        try png.write(to: url); window.close()
    }
}

private actor ExportFixtureProvider: ModelProvider {
    let svg: String
    private var calls = 0
    init(svg: String) { self.svg = svg }
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        calls += 1
        return ProviderResponse(rawResponse: svg, content: svg, usage: .init(inputTokens: 10, outputTokens: 3, totalTokens: 13), executionProfile: "self-check-fixture;cli-version=fixture")
    }
    func count() -> Int { calls }
}
