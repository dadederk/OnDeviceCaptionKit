import Foundation
import Speech
import Testing
@testable import OnDeviceCaptionKit

struct LegacySpeechRequestFactoryTests {
    @Test("Production factory requires on-device recognition")
    func givenProductionFactoryWhenMakingRequestThenRequiresOnDeviceRecognition() {
        let factory = ProductionLegacySpeechURLRecognitionRequestFactory()
        let request = factory.makeRequest(url: URL(fileURLWithPath: "/tmp/audio.m4a"))
        #expect(request.requiresOnDeviceRecognition)
    }
}
