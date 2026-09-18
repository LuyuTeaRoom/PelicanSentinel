import Foundation
import Testing
import PelicanCore
@testable import PelicanSentinel

@Suite(.serialized)
struct ImageExportTests {
    private func record(completedAt: Date = Date(timeIntervalSince1970: 0)) -> ResultRecord {
        var record = ResultRecord(
            providerId: .codex,
            startedAt: Date(timeIntervalSince1970: -60),
            completedAt: completedAt,
            generationMode: .ask,
            scheduleInterval: 4,
            status: .success
        )
        record.requestedModel = "requested-model"
        return record
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pelican-image-export-\(UUID().uuidString)", isDirectory: true)
    }

    private func rootOpeningTag(_ svg: String) throws -> String {
        let start = try #require(svg.range(of: "<svg")?.lowerBound)
        let end = try #require(svg[start...].firstIndex(of: ">"))
        return String(svg[start...end])
    }

    private func rootAttribute(_ name: String, in svg: String) throws -> String {
        let opening = try rootOpeningTag(svg)
        let marker = " \(name)=\""
        let start = try #require(opening.range(of: marker)?.upperBound)
        let end = try #require(opening[start...].firstIndex(of: "\""))
        return String(opening[start..<end])
    }

    private func viewBox(_ svg: String) throws -> [Double] {
        try rootAttribute("viewBox", in: svg)
            .split(separator: " ")
            .map { try #require(Double(String($0))) }
    }

    @Test func annotatedSVGKeepsOriginalViewportAndAspectRatio() throws {
        var imageRecord = record()
        imageRecord.returnedModel = "returned-model"
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"10 20 100 50\" width=\"200px\" height=\"100px\"><rect x=\"10\" y=\"20\" width=\"100\" height=\"50\" fill=\"red\"/></svg>"

        let annotated = try ImageExporter.annotatedSVG(svg: source, record: imageRecord, timeZone: .gmt)
        try SVGValidator.validate(annotated)

        #expect(annotated.contains("<svg x=\"10\" y=\"20\" width=\"100\" height=\"50\" viewBox=\"10 20 100 50\" preserveAspectRatio=\"none\" overflow=\"hidden\" style=\"overflow:hidden !important\">"))
        #expect(annotated.contains("<rect x=\"10\" y=\"20\" width=\"100\" height=\"50\" fill=\"red\"/>"))
        #expect(try rootAttribute("width", in: annotated) == "200px")
        let heightText = try rootAttribute("height", in: annotated)
        let expandedHeight = try #require(Double(String(heightText.dropLast(2))))
        let expandedViewBox = try viewBox(annotated)
        #expect(expandedHeight > 100)
        #expect(abs((200 / expandedHeight) - (expandedViewBox[2] / expandedViewBox[3])) < 0.001)
    }

    @Test func annotatedSVGHandlesPXAndMissingDimensions() throws {
        let pxSource = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 50\" width=\"100px\" height=\"50px\"><circle cx=\"25\" cy=\"25\" r=\"10\"/></svg>"
        let pxAnnotated = try ImageExporter.annotatedSVG(svg: pxSource, record: record(), timeZone: .gmt)
        #expect(try rootAttribute("width", in: pxAnnotated) == "100px")
        #expect((try rootAttribute("height", in: pxAnnotated)).hasSuffix("px"))

        let missingSource = "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle cx=\"25\" cy=\"25\" r=\"10\"/></svg>"
        let missingAnnotated = try ImageExporter.annotatedSVG(svg: missingSource, record: record(), timeZone: .gmt)
        #expect(try rootAttribute("width", in: missingAnnotated) == "300")
        #expect(try rootAttribute("height", in: missingAnnotated) != "150")
        let missingViewBox = try viewBox(missingAnnotated)
        #expect(Array(missingViewBox.prefix(3)) == [0, 0, 300])
    }

    @Test func annotatedSVGConvertsAbsoluteCSSLengthsWithoutViewBox() throws {
        for length in ["96", "96px", "2.54cm", "25.4mm", "1in", "72pt", "6pc"] {
            let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(length)\" height=\"\(length)\"><circle cx=\"48\" cy=\"48\" r=\"24\"/></svg>"
            let original = source

            let annotated = try ImageExporter.annotatedSVG(svg: source, record: record(), timeZone: .gmt)

            #expect(source == original)
            #expect(try rootAttribute("width", in: annotated) == length)
            #expect(annotated.contains("<svg x=\"0\" y=\"0\" width=\"96\" height=\"96\" viewBox=\"0 0 96 96\""))
            #expect(annotated.contains("<circle cx=\"48\" cy=\"48\" r=\"24\"/>"))
        }
    }

    @Test func annotatedSVGPreservesAbsoluteSizeWithANonzeroViewBoxOrigin() throws {
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"10 20 100 50\" width=\"2in\" height=\"1in\"><rect x=\"10\" y=\"20\" width=\"100\" height=\"50\"/></svg>"

        let annotated = try ImageExporter.annotatedSVG(svg: source, record: record(), timeZone: .gmt)

        #expect(try rootAttribute("width", in: annotated) == "2in")
        let expandedHeight = try #require(Double(String((try rootAttribute("height", in: annotated)).dropLast(2))))
        let expandedViewBox = try viewBox(annotated)
        #expect(annotated.contains("<svg x=\"10\" y=\"20\" width=\"100\" height=\"50\" viewBox=\"10 20 100 50\""))
        #expect(annotated.contains("<rect x=\"10\" y=\"20\" width=\"100\" height=\"50\"/>"))
        #expect(abs((2 / expandedHeight) - (expandedViewBox[2] / expandedViewBox[3])) < 0.001)
    }

    @Test func footerTextHasProvenanceTimezoneEscapingAndLongWrapping() throws {
        let halfHourZone = try #require(TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60))
        var returned = record()
        returned.returnedModel = "actual<&\"quoted\"'model>"
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 50\"><rect width=\"100\" height=\"50\"/></svg>"
        let annotated = try ImageExporter.annotatedSVG(svg: source, record: returned, timeZone: halfHourZone)
        #expect(annotated.contains("Returned model: actual&lt;&amp;&quot;quoted&quot;&apos;model&gt;"))
        #expect(annotated.contains("Completed: 1970-01-01 05:30:00 UTC+05:30"))

        var requested = record()
        requested.returnedModel = " \n"
        requested.requestedModel = String(repeating: "very-long-model-label-", count: 80)
        let longAnnotated = try ImageExporter.annotatedSVG(svg: source, record: requested, timeZone: halfHourZone)
        #expect(longAnnotated.contains("Requested model:"))
        #expect(longAnnotated.components(separatedBy: "<text ").count > 3)
        try SVGValidator.validate(longAnnotated)
    }

    @Test func annotationRejectsUnresolvedRootCSSDimensions() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"300\" height=\"200\" style=\"height: 50vh\"><circle r=\"10\"/></svg>"
        #expect(throws: (any Error).self) { try ImageExporter.annotatedSVG(svg: svg, record: record()) }
    }

    @Test func annotatedSVGRejectsMalformedAndUnsafeInput() {
        #expect(throws: (any Error).self) {
            try ImageExporter.annotatedSVG(svg: "<svg><rect></svg>", record: record())
        }
        #expect(throws: (any Error).self) {
            try ImageExporter.annotatedSVG(svg: "<svg><script>alert(1)</script><rect/></svg>", record: record())
        }
        #expect(throws: (any Error).self) {
            try ImageExporter.annotatedSVG(svg: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 50\" width=\"100%\" height=\"50px\"><rect width=\"100\" height=\"50\"/></svg>", record: record())
        }
        #expect(throws: (any Error).self) {
            try ImageExporter.annotatedSVG(svg: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4em\" height=\"50\"><rect width=\"100\" height=\"50\"/></svg>", record: record())
        }
        #expect(throws: (any Error).self) {
            try ImageExporter.annotatedSVG(svg: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"0cm\" height=\"50\"><rect width=\"100\" height=\"50\"/></svg>", record: record())
        }
    }

    @Test func exportWritesCallerSuppliedAnnotatedSVGAndCleanPNG() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let annotatedSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>footer already present</text></svg>\n"
        let cleanPNG = Data("clean-png-bytes".utf8)

        let files = try ImageExporter.export(svg: annotatedSVG, png: cleanPNG, record: record(), directory: root)
        let png = try #require(files.png)

        #expect(files.svg.deletingLastPathComponent() == png.deletingLastPathComponent())
        #expect(files.svg.lastPathComponent == "pelican.svg")
        #expect(png.lastPathComponent == "pelican.png")
        #expect(try Data(contentsOf: files.svg) == Data(annotatedSVG.utf8))
        #expect(try Data(contentsOf: png) == cleanPNG)
    }

    @Test func exportWritesSVGWithoutPNGWhenNoThumbnailIsAvailable() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>footer already present</text></svg>\n"

        let files = try ImageExporter.export(svg: svg, png: nil, record: record(), directory: root)

        #expect(files.png == nil)
        #expect(try Data(contentsOf: files.svg) == Data(svg.utf8))
        #expect(!FileManager.default.fileExists(atPath: files.svg.deletingLastPathComponent().appendingPathComponent("pelican.png").path))
    }

    @Test func duplicateExportNeverOverwritesEarlierExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageRecord = record()
        let cleanPNG = Data("clean-png-bytes".utf8)
        let first = try ImageExporter.export(svg: "<svg>first</svg>", png: cleanPNG, record: imageRecord, directory: root)
        let second = try ImageExporter.export(svg: "<svg>second</svg>", png: cleanPNG, record: imageRecord, directory: root)
        let firstPNG = try #require(first.png)
        let secondPNG = try #require(second.png)

        #expect(first.svg.deletingLastPathComponent() != second.svg.deletingLastPathComponent())
        #expect(try String(contentsOf: first.svg, encoding: .utf8) == "<svg>first</svg>")
        #expect(try String(contentsOf: second.svg, encoding: .utf8) == "<svg>second</svg>")
        #expect(try Data(contentsOf: firstPNG) == cleanPNG)
        #expect(try Data(contentsOf: secondPNG) == cleanPNG)
    }

    @Test func invalidDestinationLeavesExistingFileUntouched() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalidDestination = root.appendingPathComponent("not-a-directory")
        let original = Data("existing file".utf8)
        try original.write(to: invalidDestination)

        #expect(throws: (any Error).self) {
            try ImageExporter.export(svg: "<svg/>", png: Data(), record: record(), directory: invalidDestination)
        }
        #expect(try Data(contentsOf: invalidDestination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["not-a-directory"])
    }
}
