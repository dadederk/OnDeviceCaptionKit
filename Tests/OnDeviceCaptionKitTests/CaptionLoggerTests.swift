import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct CaptionLoggerTests {
    @Test("Package logs use the host subsystem and subtitles category")
    func loggerIdentityMatchesHostApplication() {
        #expect(CaptionLogger.subsystem == (Bundle.main.bundleIdentifier ?? "OnDeviceCaptionKit"))
        #expect(CaptionLogger.category == "subtitles")
    }
}
