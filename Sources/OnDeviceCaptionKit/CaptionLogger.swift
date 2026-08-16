import Foundation
import os

enum CaptionLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "OnDeviceCaptionKit"
    static let category = "subtitles"

    private static let logger = Logger(
        subsystem: subsystem,
        category: category
    )

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    #if DEBUG
    static func debugTranscript(_ message: String, enabled: Bool) {
        guard enabled else { return }
        logger.debug("\(message, privacy: .public)")
    }
    #endif
}
