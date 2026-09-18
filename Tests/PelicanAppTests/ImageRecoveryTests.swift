import Foundation
import AppKit
import Testing
import PelicanCore
@testable import PelicanSentinel

private actor RecoveryFixture: ModelProvider {
    let svg: String
    var calls = 0
    init(_ svg: String) { self.svg = svg }
    func generate(_ request: GenerationRequest) async throws -> ProviderResponse {
        calls += 1
        return .init(rawResponse: "RAW " + svg, content: svg, returnedModel: "fixture-model", usage: .init(totalTokens: 17), executionProfile: "fixture;cli-version=1")
    }
    func count() -> Int { calls }
}
@Suite(.serialized) @MainActor
struct ImageRecoveryTests {
    private let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 300 200\"><circle cx=\"150\" cy=\"100\" r=\"70\"/></svg>"
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func failedExportRetriesSameRecordToCorrectedFolderWithoutModelCall() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true), fixture = RecoveryFixture(svg)
        let generated = try await model.service.generate(provider: fixture, settings: model.settings, thumbnail: { _ in png })
        let blocked = root.appendingPathComponent("blocked")
        try Data("keep".utf8).write(to: blocked)
        var settings = model.settings; settings.imageSavePath = blocked.path
        let failed = model.finalizeImages(generated, settings: settings)
        #expect(failed.status == .success && failed.imageExportError != nil)
        try model.reloadHistory()
        let before = try #require(model.records.first)
        #expect(model.pendingExports.map(\.id) == [before.id])
        let folder = root.appendingPathComponent("corrected")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(model.setImageSaveDirectory(folder))
        await model.recoverLocalResult(before.id, exportImages: true)
        let after = try #require(model.records.first)
        #expect(after.id == before.id && after.completedAt == before.completedAt && after.startedAt == before.startedAt)
        #expect(after.usage == before.usage && after.rawResponsePath == before.rawResponsePath && after.svgPath == before.svgPath)
        #expect(after.imageExportError == nil && after.savedSVGPath != nil && after.savedImagePath != nil)
        #expect(model.pendingExports.isEmpty && !model.processingLocalImages)
        #expect(await fixture.count() == 1 && model.records.count == 1)
        #expect(try String(contentsOf: blocked) == "keep")
        let exported = try #require(after.savedSVGPath)
        #expect(try String(contentsOfFile: exported).contains("fixture-model"))
        let source = try #require(after.svgPath)
        #expect(try String(contentsOf: model.store.url(for: source)!) == svg)
    }

    @Test func thumbnailFailureStillExportsSVGAndCanRecoverPreviewAndPNG() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true), fixture = RecoveryFixture(svg)
        let generated = try await model.service.generate(provider: fixture, settings: model.settings, thumbnail: { _ in throw CocoaError(.fileReadCorruptFile) })
        let exported = model.finalizeImages(generated, settings: model.settings)
        #expect(exported.status == .success && exported.errorType == "thumbnail_error")
        #expect(exported.savedSVGPath != nil && exported.savedImagePath == nil && exported.imageExportError == nil)
        #expect(exported.annotatedSVGPath != nil && model.image(for: exported) == nil)
        #expect(model.rebuildingPreviewID == nil && !model.preparingHistory)
        let originalExport = try #require(exported.savedSVGPath)
        let originalExportBytes = try Data(contentsOf: URL(fileURLWithPath: originalExport))
        await model.recoverLocalResult(exported.id, exportImages: false, renderer: { _ in png })
        let rebuilt = try #require(model.records.first)
        #expect(rebuilt.errorType == nil && rebuilt.errorMessage == nil && model.image(for: rebuilt) != nil)
        #expect(rebuilt.savedSVGPath == originalExport)
        await model.recoverLocalResult(rebuilt.id, exportImages: true)
        let saved = try #require(model.records.first)
        #expect(saved.savedImagePath != nil && saved.imageExportError == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: originalExport)) == originalExportBytes)
        #expect(await fixture.count() == 1 && saved.usage.totalTokens == 17)
    }

    @Test func annotationFailureExportsOriginalAndDoesNotHideCleanPreview() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        let relativeSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50%\" height=\"10em\"><circle r=\"10\"/></svg>"
        let fixture = RecoveryFixture(relativeSVG)
        let generated = try await model.service.generate(provider: fixture, settings: model.settings, thumbnail: { _ in png })
        let saved = model.finalizeImages(generated, settings: model.settings)
        #expect(saved.annotationError != nil && saved.annotatedSVGPath == nil)
        #expect(saved.imageExportError == nil && model.image(for: saved) != nil)
        let savedPath = try #require(saved.savedSVGPath)
        #expect(try String(contentsOfFile: savedPath) == relativeSVG)
        let preview = try model.previewURL(for: saved)
        #expect(preview == saved.svgPath.flatMap(model.store.url(for:)))
        #expect(saved.status == .success)
        #expect(await fixture.count() == 1)
    }

    @Test func failedPreviewRecoveryStopsWaitingAndCanRetryAgain() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        let generated = try await model.service.generate(provider: RecoveryFixture(svg), settings: model.settings)
        await model.recoverLocalResult(generated.id, exportImages: false, renderer: { _ in throw CocoaError(.fileReadCorruptFile) })
        let failed = try #require(model.records.first)
        #expect(failed.errorType == "thumbnail_error" && model.image(for: failed) == nil)
        #expect(model.rebuildingPreviewID == nil && !model.processingLocalImages)
        await model.recoverLocalResult(generated.id, exportImages: false, renderer: { _ in png })
        let recovered = try #require(model.records.first)
        #expect(recovered.errorType == nil && model.image(for: recovered) != nil)
        #expect(model.rebuildingPreviewID == nil && !model.processingLocalImages)
    }

    @Test func concurrentRecoveryDoesNotStartSecondOperation() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, testing: true)
        let generated = try await model.service.generate(provider: RecoveryFixture(svg), settings: model.settings)
        var renderCount = 0
        let first = Task { await model.recoverLocalResult(generated.id, exportImages: false, renderer: { _ in renderCount += 1; try await Task.sleep(nanoseconds: 40_000_000); return png }) }
        await Task.yield()
        await model.recoverLocalResult(generated.id, exportImages: false, renderer: { _ in renderCount += 1; return png })
        await first.value
        #expect(renderCount == 1 && model.localWorkRecordID == nil)
    }
}
