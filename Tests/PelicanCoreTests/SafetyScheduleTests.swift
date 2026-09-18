import Foundation
import Testing
@testable import PelicanCore

struct SafetyScheduleTests {
    private let validSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>"

    @Test
    func extractorSupportsPlainMarkdownAndExplanatoryText() throws {
        let plain = try SVGExtractor.extract(from: validSVG)
        #expect(plain == validSVG)

        let response = "Here is the image:\n```xml\n\(validSVG)\n```\nDone."
        #expect(try SVGExtractor.extract(from: response) == validSVG)
    }

    @Test
    func extractorKeepsFirstCandidateEvenWhenUnsafe() throws {
        let first = "<svg><script>alert(1)</script></svg>"
        let response = "\(first)<svg><rect/></svg>"
        let extracted = try SVGExtractor.extract(from: response)
        #expect(extracted == first)
        #expect(throws: (any Error).self) {
            try SVGValidator.validate(extracted)
        }
    }

    @Test
    func extractorRejectsEmptyMissingAndBrokenResponses() {
        #expect(throws: (any Error).self) { try SVGExtractor.extract(from: "") }
        #expect(throws: (any Error).self) { try SVGExtractor.extract(from: "no SVG here") }
        #expect(throws: (any Error).self) { try SVGExtractor.extract(from: "<svg><rect/></svg") }
    }

    @Test
    func validatorAcceptsLocalGradientAndOrdinaryStyle() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg">
          <defs><linearGradient id="gradient"><stop offset="0%"/></linearGradient></defs>
          <rect style="fill: url(#gradient); stroke: #111; stroke-width: 2" fill="url(#gradient)"/>
        </svg>
        """
        try SVGValidator.validate(svg)
    }

    @Test
    func validatorAcceptsCSSCommentsWithoutChangingSVG() throws {
        let styleAttribute = "<svg><rect style=\"fill: red; /* palette */ stroke: blue\"/></svg>"
        try SVGValidator.validate(styleAttribute)
        #expect(try SVGExtractor.extract(from: styleAttribute) == styleAttribute)

        let styleElement = "<svg><style>/* palette */ rect { fill: red; }</style><rect/></svg>"
        try SVGValidator.validate(styleElement)
        #expect(try SVGExtractor.extract(from: styleElement) == styleElement)

        let cdata = "<svg><style><![CDATA[/* palette */ rect { fill: red; }]]></style><rect/></svg>"
        try SVGValidator.validate(cdata)

        let quotedMarkers = #"<svg><rect style="content: '/* literal */'; fill: red"/></svg>"#
        try SVGValidator.validate(quotedMarkers)

        let ignoredDangerousText = "<svg><style>/* @import url(https://example.com/a.css) javascript: */ rect { fill: red; }</style><rect/></svg>"
        try SVGValidator.validate(ignoredDangerousText)
    }

    @Test
    func validatorRejectsEmptyAndMalformedXML() {
        #expect(throws: (any Error).self) { try SVGValidator.validate("<svg/>") }
        #expect(throws: (any Error).self) { try SVGValidator.validate("<svg></svg>") }
        #expect(throws: (any Error).self) { try SVGValidator.validate("<svg><rect></svg>") }
    }

    @Test
    func validatorRejectsScriptsForeignObjectsEventsAndDangerousNamespaces() {
        let cases = [
            "<svg><script>alert(1)</script><rect/></svg>",
            "<svg><foreignObject><div>unsafe</div></foreignObject></svg>",
            "<svg><rect onload=\"alert(1)\"/></svg>",
            "<svg xmlns:ev=\"urn:events\"><rect ev:event=\"load\"/></svg>",
            "<svg xmlns:evil=\"urn:evil\"><evil:payload/><rect/></svg>",
            "<svg><set attributeName=\"href\" to=\"https://example.com/a.svg\"/></svg>",
            "<svg><animate attributeName=\"fill\" values=\"url(https://example.com/fill)\"/><rect/></svg>",
            "<svg><animateTransform attributeName=\"transform\" to=\"rotate(10)\"/><rect/></svg>"
        ]
        for svg in cases {
            #expect(throws: (any Error).self) { try SVGValidator.validate(svg) }
        }
    }

    @Test
    func validatorRejectsExternalAndObfuscatedReferences() {
        let cases = [
            "<svg><image href=\"https://example.com/a.png\"/></svg>",
            "<svg><image href=\"icons/a.png\"/></svg>",
            "<svg><a href=\"javascript:alert(1)\"><rect/></a></svg>",
            "<svg><rect fill=\"url(https://example.com/fill)\"/></svg>",
            "<svg><style>@import url(https://example.com/a.css);</style><rect/></svg>",
            "<svg><style>u\\72l(https://example.com/a)</style><rect/></svg>",
            "<svg><rect fill=\"u\\72l(https://example.com/a)\"/></svg>",
            "<svg><rect style=\"background-image: image-set('https://example.com/a.png')\"/></svg>",
            "<svg><rect style=\"background-image: image-set('relative.png')\"/></svg>",
            "<svg><rect style=\"@supports (display:block) { fill:red; }\"/></svg>",
            "<svg><rect style=\"fill: u/* split */rl(https://example.com/a)\"/></svg>",
            "<svg><rect style=\"fill: url/* split */(https://example.com/a)\"/></svg>",
            "<svg><rect style=\"fill: j/* split */avascript:alert(1)\"/></svg>",
            "<svg><rect href=\"h&#x74;tp://example.com\"/></svg>",
            "<svg><rect href=\"data:image/svg+xml;base64,abc\"/></svg>",
            "<svg><rect href=\"file:///tmp/a\"/></svg>"
        ]
        for svg in cases {
            #expect(throws: (any Error).self) { try SVGValidator.validate(svg) }
        }
    }

    @Test
    func validatorRejectsUnclosedAndStrayCSSComments() {
        let cases = [
            "<svg><style>/* unclosed</style><rect/></svg>",
            "<svg><style>rect { fill: red; } */</style><rect/></svg>",
            "<svg><rect style=\"fill: red /* unclosed\"/></svg>",
            "<svg><rect style=\"fill: red */\"/></svg>"
        ]
        for svg in cases {
            #expect(throws: (any Error).self) { try SVGValidator.validate(svg) }
        }
    }

    @Test
    func validatorRejectsDTDAndEntities() {
        let doctype = "<!DOCTYPE svg [<!ENTITY xxe SYSTEM \"file:///tmp/secret\">]><svg>&xxe;</svg>"
        #expect(throws: (any Error).self) { try SVGValidator.validate(doctype) }
        #expect(throws: (any Error).self) {
            try SVGValidator.validate("<svg><?xml-stylesheet href=\"https://example.com/a.css\"?><rect/></svg>")
        }
    }

    @Test
    func validatorEnforcesSizeAndComplexityLimits() {
        let manyNodes = "<svg>" + String(repeating: "<rect/>", count: 10_001) + "</svg>"
        #expect(throws: (any Error).self) { try SVGValidator.validate(manyNodes) }

        var nested = "<svg>"
        for _ in 0..<65 { nested += "<g>" }
        nested += "<rect/>"
        for _ in 0..<65 { nested += "</g>" }
        nested += "</svg>"
        #expect(throws: (any Error).self) { try SVGValidator.validate(nested) }
    }

    @Test
    func rescheduleUsesAllowedHoursAndDefaultsInvalidValuesToFour() {
        let origin = Date(timeIntervalSince1970: 0)
        #expect(SchedulePolicy.reschedule(now: origin, intervalHours: 1) == Date(timeIntervalSince1970: 3_600))
        #expect(SchedulePolicy.reschedule(now: origin, intervalHours: 2) == Date(timeIntervalSince1970: 7_200))
        #expect(SchedulePolicy.reschedule(now: origin, intervalHours: 4) == Date(timeIntervalSince1970: 14_400))
        #expect(SchedulePolicy.reschedule(now: origin, intervalHours: 3) == Date(timeIntervalSince1970: 14_400))
    }

    @Test
    func consumeDueUsesScheduledTimeAndReturnsNilBeforeDue() {
        let origin = Date(timeIntervalSince1970: 0)
        #expect(SchedulePolicy.consumeDue(next: origin.addingTimeInterval(3_600), now: origin.addingTimeInterval(3_599), intervalHours: 1) == nil)

        let due = SchedulePolicy.consumeDue(next: origin.addingTimeInterval(3_600), now: origin.addingTimeInterval(3_600), intervalHours: 1)
        #expect(due?.scheduledAt == origin.addingTimeInterval(3_600))
        #expect(due?.next == origin.addingTimeInterval(7_200))
    }

    @Test
    func consumeDueSkipsMissedSleepRunsAndAdvancesPastNow() {
        let origin = Date(timeIntervalSince1970: 0)
        let now = origin.addingTimeInterval(8 * 3_600)
        let due = SchedulePolicy.consumeDue(next: origin, now: now, intervalHours: 4)
        #expect(due?.scheduledAt == origin)
        #expect(due?.next == origin.addingTimeInterval(12 * 3_600))
    }

    @Test
    func repeatedWakeCannotConsumeSameOverdueActionTwice() {
        let origin = Date(timeIntervalSince1970: 0)
        let now = origin.addingTimeInterval(8 * 3_600)
        guard let first = SchedulePolicy.consumeDue(next: origin, now: now, intervalHours: 4) else {
            Issue.record("expected one overdue action")
            return
        }
        #expect(SchedulePolicy.consumeDue(next: first.next, now: now, intervalHours: 4) == nil)
    }

    @Test
    func frequencyChangeReschedulesFromNowAndInvalidConsumeDefaultsToFourHours() {
        let origin = Date(timeIntervalSince1970: 100)
        let changed = SchedulePolicy.reschedule(now: origin, intervalHours: 2)
        #expect(changed == origin.addingTimeInterval(7_200))

        let due = SchedulePolicy.consumeDue(next: origin, now: origin.addingTimeInterval(5 * 3_600), intervalHours: 3)
        #expect(due?.next == origin.addingTimeInterval(8 * 3_600))
    }
}
