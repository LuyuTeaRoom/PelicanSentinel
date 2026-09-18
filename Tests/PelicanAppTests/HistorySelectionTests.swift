import Foundation
import Testing
import PelicanCore
@testable import PelicanSentinel

@Suite(.serialized) @MainActor
struct HistorySelectionTests {
    @Test func rowsSelectTheirOwnResultIncludingFailureWithoutOpeningFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        var newest = ResultRecord(providerId: .codex, startedAt: Date(timeIntervalSince1970: 30), generationMode: .ask, scheduleInterval: 4, status: .success)
        var failed = newest; failed.id = UUID(); failed.startedAt = Date(timeIntervalSince1970: 20); failed.status = .apiError
        var older = newest; older.id = UUID(); older.startedAt = Date(timeIntervalSince1970: 10)
        newest.requestedModel = model.configuration.model
        model.records = [newest, failed, older]
        #expect(model.displayedRecord?.id == newest.id)
        model.selectRecord(older)
        #expect(model.displayedRecord?.id == older.id)
        #expect(model.latest?.id == newest.id)
        model.selectRecord(failed)
        #expect(model.displayedRecord?.id == failed.id)
        #expect(model.displayedRecord?.status == .apiError)
        #expect(try model.previewURL(for: failed) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("results").path).isEmpty)
        model.selectRecord(newest)
        #expect(model.displayedRecord?.id == newest.id)
        model.setProvider(.gemini)
        #expect(model.selectedRecordID == nil)
        #expect(model.displayedRecord == nil)
    }
    @Test func arrowPreparesMatchingAnnotatedSVGWithoutChangingSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        var first = ResultRecord(providerId: .codex, startedAt: Date(timeIntervalSince1970: 30), generationMode: .ask, scheduleInterval: 4, status: .success)
        var second = first; second.id = UUID(); second.startedAt = Date(timeIntervalSince1970: 20)
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 300 200\"><circle cx=\"100\" cy=\"80\" r=\"20\"/></svg>"
        first.svgPath = try model.store.saveText(source, id: first.id, suffix: "svg")
        second.svgPath = try model.store.saveText(source.replacingOccurrences(of: "circle", with: "ellipse"), id: second.id, suffix: "svg")
        try model.store.save(first); try model.store.save(second); try model.reloadHistory()
        model.selectRecord(first)
        let preparedURL = try model.previewURL(for: second)
        let url = try #require(preparedURL)
        #expect(url.lastPathComponent == second.id.uuidString + ".annotated.svg")
        let labeled = try String(contentsOf: url)
        #expect(labeled.contains("ellipse"))
        #expect(labeled.contains("Requested model:"))
        #expect(labeled.contains("Completed:"))
        #expect(model.selectedRecordID == first.id)
        let firstPath = try #require(first.svgPath)
        let firstURL = try #require(model.store.url(for: firstPath))
        #expect(try String(contentsOf: firstURL) == source)
        #expect(model.records.first(where: { $0.id == second.id })?.annotatedSVGPath != nil)
    }
    @Test func disappearedSelectionFallsBackToLatestAndNewGenerationKeepsExistingSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        let older = ResultRecord(providerId: .codex, startedAt: Date(timeIntervalSince1970: 1), generationMode: .ask, scheduleInterval: 4, status: .success)
        try model.store.save(older); try model.reloadHistory(); model.selectRecord(older)
        var newer = older; newer.id = UUID(); newer.startedAt = Date(timeIntervalSince1970: 2)
        try model.store.save(newer); try model.reloadHistory()
        #expect(model.displayedRecord?.id == older.id)
        try FileManager.default.removeItem(at: root.appendingPathComponent("results/\(older.id.uuidString).json"))
        try model.reloadHistory()
        #expect(model.selectedRecordID == nil)
        #expect(model.displayedRecord?.id == newer.id)
    }
}
