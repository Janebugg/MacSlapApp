import Foundation

/// A span after a lid, charger or cable event during which detections are
/// dropped: those events jolt the chassis just like a slap does.
public struct QuietWindow: Sendable {
    public let duration: TimeInterval
    public private(set) var reason: String?
    private var until: Date = .distantPast

    public init(duration: TimeInterval) {
        self.duration = duration
    }

    public mutating func start(reason: String, at now: Date = Date()) {
        until = max(until, now.addingTimeInterval(duration))
        self.reason = reason
    }

    public func isQuiet(at now: Date = Date()) -> Bool {
        now < until
    }
}
