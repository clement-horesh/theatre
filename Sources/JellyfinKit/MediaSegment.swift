import Foundation

public struct MediaSegment: Codable, Sendable, Equatable {
    public let type: String
    public let startTicks: Int64
    public let endTicks: Int64?
    public var startSeconds: Double { Double(startTicks) / 10_000_000 }
    public var endSeconds: Double? { endTicks.map { Double($0) / 10_000_000 } }
    public var isSkippable: Bool { startTicks >= 0 && (endTicks ?? 0) > startTicks }

    public func contains(seconds: Double) -> Bool {
        isSkippable && seconds.isFinite && seconds >= startSeconds && seconds < (endSeconds ?? 0)
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case startTicks = "StartTicks"
        case endTicks = "EndTicks"
    }
}
