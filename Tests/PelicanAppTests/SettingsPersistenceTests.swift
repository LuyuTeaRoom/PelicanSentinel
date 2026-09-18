import Foundation
import Testing
import PelicanCore
@testable import PelicanSentinel

@Suite(.serialized) @MainActor
struct SettingsPersistenceTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pelican-settings-test-\(UUID().uuidString)")
    }

    private func baselineSettings() -> AppSettings {
        var settings = AppSettings()
        settings.mode = .ask
        settings.intervalHours = 4
        settings.nextScheduledAt = Date(timeIntervalSince1970: 1_900_000_000)
        settings.pendingScheduledAt = Date(timeIntervalSince1970: 1_899_999_000)
        return settings
    }

    private func expectScheduleFields(_ actual: AppSettings, matching expected: AppSettings) {
        #expect(actual.mode == expected.mode)
        #expect(actual.intervalHours == expected.intervalHours)
        #expect(actual.pendingScheduledAt == expected.pendingScheduledAt)
        #expect(actual.nextScheduledAt == expected.nextScheduledAt)
    }

    private func blockSettingsFile(in root: URL) throws -> URL {
        let fileManager = FileManager.default
        let settingsURL = root.appendingPathComponent("settings.json")
        let backupURL = root.appendingPathComponent("settings-before-failure.json")
        try fileManager.moveItem(at: settingsURL, to: backupURL)
        try fileManager.createDirectory(at: settingsURL, withIntermediateDirectories: false)
        return backupURL
    }

    private func restoreSettingsFile(in root: URL, from backupURL: URL) throws {
        let fileManager = FileManager.default
        let settingsURL = root.appendingPathComponent("settings.json")
        if fileManager.fileExists(atPath: settingsURL.path) {
            try fileManager.removeItem(at: settingsURL)
        }
        try fileManager.moveItem(at: backupURL, to: settingsURL)
    }

    @Test func intervalSaveFailurePreservesMemoryAndPersistedBaseline() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        let baseline = baselineSettings()
        model.settings = baseline
        try model.store.saveSettings(baseline)
        let backupURL = try blockSettingsFile(in: root)

        model.setInterval(1)

        expectScheduleFields(model.settings, matching: baseline)
        #expect(model.message == "无法保存设置，请检查存储权限。")
        try restoreSettingsFile(in: root, from: backupURL)
        expectScheduleFields(try model.store.settings(), matching: baseline)
    }

    @Test func modeSaveFailurePreservesMemoryAndPersistedBaseline() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        let baseline = baselineSettings()
        model.settings = baseline
        try model.store.saveSettings(baseline)
        let backupURL = try blockSettingsFile(in: root)

        model.setMode(.automatic)

        expectScheduleFields(model.settings, matching: baseline)
        #expect(model.message == "无法保存设置，请检查存储权限。")
        try restoreSettingsFile(in: root, from: backupURL)
        expectScheduleFields(try model.store.settings(), matching: baseline)
    }

    @Test func successfulChangesPersistAndRemainAllowedDuringGeneration() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        model.settings = baselineSettings()
        try model.store.saveSettings(model.settings)
        model.generating = true

        model.setInterval(1)

        #expect(model.settings.intervalHours == 1)
        #expect(model.settings.pendingScheduledAt == nil)
        let intervalNext = model.settings.nextScheduledAt
        #expect(intervalNext > Date())
        #expect(try model.store.settings().intervalHours == 1)

        model.settings.pendingScheduledAt = Date(timeIntervalSince1970: 1_899_998_000)
        try model.store.saveSettings(model.settings)
        model.setMode(.automatic)

        #expect(model.settings.mode == .automatic)
        #expect(model.settings.intervalHours == 1)
        #expect(model.settings.nextScheduledAt == intervalNext)
        #expect(model.settings.pendingScheduledAt == nil)
        let persisted = try model.store.settings()
        #expect(persisted.mode == .automatic)
        #expect(persisted.intervalHours == 1)
        #expect(Int(persisted.nextScheduledAt.timeIntervalSince1970) == Int(intervalNext.timeIntervalSince1970))
        #expect(persisted.pendingScheduledAt == nil)

        let reopened = try AppModel(root: root, testing: true)
        #expect(reopened.settings.mode == .automatic)
        #expect(reopened.settings.intervalHours == 1)
        #expect(Int(reopened.settings.nextScheduledAt.timeIntervalSince1970) == Int(intervalNext.timeIntervalSince1970))
        #expect(reopened.settings.pendingScheduledAt == nil)
    }

    @Test func invalidIntervalAndShutdownLeaveSettingsUntouched() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        let baseline = baselineSettings()
        model.settings = baseline
        try model.store.saveSettings(baseline)

        model.setInterval(3)
        expectScheduleFields(model.settings, matching: baseline)
        model.shuttingDown = true
        model.setInterval(1)
        model.setMode(.automatic)

        expectScheduleFields(model.settings, matching: baseline)
        expectScheduleFields(try model.store.settings(), matching: baseline)
    }
}
