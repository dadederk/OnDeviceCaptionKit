import Foundation

public struct CaptionSegment: Equatable, Sendable {
    public let index: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public var duration: TimeInterval {
        endTime - startTime
    }

    public init(index: Int, startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}
