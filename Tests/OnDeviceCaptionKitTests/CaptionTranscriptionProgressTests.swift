import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct CaptionTranscriptionProgressTests {
    @Test("Stream progress reaches 92% at end of audio timeline")
    func givenFullAudioTimelineWhenReportingStreamProgressThenHeadroomIsReserved() {
        let progress = CaptionTranscriptionProgress.streamProgress(processedSeconds: 13, totalSeconds: 13)
        #expect(progress == 0.92)
    }

    @Test("Stream progress maps halfway through audio to half of headroom")
    func givenHalfAudioTimelineWhenReportingStreamProgressThenProgressIsScaled() {
        let progress = CaptionTranscriptionProgress.streamProgress(processedSeconds: 6.5, totalSeconds: 13)
        #expect(abs(progress - 0.46) < 0.001)
    }

    @Test("Progress reporter ignores tiny regressions and duplicate updates")
    func givenDuplicateProgressWhenReportingThenHandlerIsNotCalledAgain() {
        var lastReported = 0.0
        let counter = CallCounter()
        let handler: @Sendable (Double) -> Void = { _ in counter.increment() }

        CaptionTranscriptionProgress.reportStreamProgress(
            processedSeconds: 1,
            totalSeconds: 10,
            lastReported: &lastReported,
            handler: handler
        )
        CaptionTranscriptionProgress.reportStreamProgress(
            processedSeconds: 1.01,
            totalSeconds: 10,
            lastReported: &lastReported,
            handler: handler
        )

        #expect(counter.value == 1)
    }
}

private final class CallCounter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}
