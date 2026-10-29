import Foundation
import Testing
@testable import SlapCore

@Suite("QuietWindow")
struct QuietWindowTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("Not quiet before any event")
    func idle() {
        #expect(!QuietWindow(duration: 3).isQuiet(at: t0))
    }

    @Test("Quiet for the duration after an event, then not")
    func expires() {
        var window = QuietWindow(duration: 3)
        window.start(reason: "lid", at: t0)
        #expect(window.isQuiet(at: t0))
        #expect(window.isQuiet(at: t0.addingTimeInterval(2.9)))
        #expect(!window.isQuiet(at: t0.addingTimeInterval(3)))
        #expect(window.reason == "lid")
    }

    @Test("A later event extends the window")
    func extends() {
        var window = QuietWindow(duration: 3)
        window.start(reason: "lid", at: t0)
        window.start(reason: "power", at: t0.addingTimeInterval(2))
        #expect(window.isQuiet(at: t0.addingTimeInterval(4.9)))
        #expect(window.reason == "power")
    }
}
