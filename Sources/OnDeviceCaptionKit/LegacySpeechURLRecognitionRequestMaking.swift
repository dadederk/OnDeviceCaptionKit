import Foundation
import Speech

protocol LegacySpeechURLRecognitionRequestMaking: Sendable {
    func makeRequest(url: URL) -> SFSpeechURLRecognitionRequest
}

struct ProductionLegacySpeechURLRecognitionRequestFactory: LegacySpeechURLRecognitionRequestMaking {
    func makeRequest(url: URL) -> SFSpeechURLRecognitionRequest {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        return request
    }
}
