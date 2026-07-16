import Foundation
import Speech

public protocol SpeechAuthorizationProviding: Sendable {
    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus
}

public struct SystemSpeechAuthorizationProvider: SpeechAuthorizationProviding {
    public init() {}

    public func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
