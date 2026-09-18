import Foundation
import Testing
import PelicanCore
@testable import PelicanSentinel

@Suite(.serialized) @MainActor
struct LanguageStorageTests {
    @Test func languageSwitchKeepsScheduleProvidersAndHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        #expect(model.settings.language == .chinese)
        model.setProvider(.compatible)
        #expect(model.saveConfiguration(.init(model: "chosen-local", baseURL: "http://localhost:11434/v1")))
        let scheduled = Date(timeIntervalSince1970: 1_800_000_000)
        model.settings.pendingScheduledAt = scheduled
        let next = model.settings.nextScheduledAt
        let record = ResultRecord(providerId: .codex, generationMode: .ask, scheduleInterval: 4, status: .success)
        try model.store.save(record)
        model.setLanguage(.english)
        #expect(model.l("留下一张，此刻的鹈鹕", "Now，Plican Check") == "Now，Plican Check")
        #expect(model.settings.provider == .compatible)
        #expect(model.configuration.model == "chosen-local")
        #expect(model.settings.nextScheduledAt == next)
        #expect(model.settings.pendingScheduledAt == scheduled)
        #expect(try model.store.records().map(\.id) == [record.id])
        let reopened = try AppModel(root: root, testing: true)
        #expect(reopened.settings.language == .english)
        #expect(reopened.configuration.model == "chosen-local")
        reopened.setLanguage(.chinese)
        #expect(reopened.l("中文", "English") == "中文")
        #expect(ProviderID.allCases.count == 5)
        #expect(ProviderID.compatible.title(in: .chinese).contains("兼容"))
    }
    @Test func chosenFolderPersistsAndFailedSelectionKeepsPreviousFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        let chosen = root.appendingPathComponent("自选鹈鹕 图片")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        #expect(model.setImageSaveDirectory(chosen))
        #expect(try model.store.settings().imageSavePath == chosen.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: chosen.path).isEmpty)
        let file = root.appendingPathComponent("not-a-folder")
        try Data("keep".utf8).write(to: file)
        #expect(!model.setImageSaveDirectory(file))
        #expect(model.imageSaveDirectory.path == chosen.path)
        model.generating = true
        #expect(!model.setImageSaveDirectory(root))
        #expect(model.imageSaveDirectory.path == chosen.path)
        model.generating = false
        let reopened = try AppModel(root: root, testing: true)
        #expect(reopened.imageSaveDirectory.path == chosen.path)
        #expect(try String(contentsOf: file) == "keep")
    }
}
