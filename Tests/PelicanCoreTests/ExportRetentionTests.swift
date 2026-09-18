import Foundation
import Testing
@testable import PelicanCore

@Suite struct ExportRetentionTests {
    @Test func keepsOnlyExplicitFailedExportsWithoutACopyAndResumesCleanupAfterRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ResultStore(root: root)
        let now = Date()
        var failed = ResultRecord(providerId: .codex, completedAt: now.addingTimeInterval(-31 * 86400), generationMode: .ask, scheduleInterval: 4, status: .success)
        failed.svgPath = try store.saveText("original", id: failed.id, suffix: "svg")
        failed.imageExportError = "disk unavailable"
        failed.savedSVGPath = root.appendingPathComponent("missing-copy.svg").path
        try store.save(failed)
        var legacy = failed; legacy.id = UUID(); legacy.svgPath = nil; legacy.imageExportError = nil
        try store.save(legacy)
        try store.prune(now: now)
        #expect(try store.records().map(\.id) == [failed.id])
        #expect(try String(contentsOf: store.url(for: failed.svgPath!)!) == "original")
        let external = root.appendingPathComponent("exported.svg")
        try Data("saved copy".utf8).write(to: external)
        failed.savedSVGPath = external.path; failed.imageExportError = nil
        try store.save(failed); try store.prune(now: now)
        #expect(try store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: failed.svgPath!)!.path))
        #expect(try String(contentsOf: external) == "saved copy")
    }
}
