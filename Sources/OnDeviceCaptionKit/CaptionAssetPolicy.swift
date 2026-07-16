import Foundation

public enum CaptionAssetPolicy: Sendable, Equatable {
    case requireExplicitConsent
}

public struct CaptionAssetDownloadRequirement: Sendable, Equatable {
    public let locale: Locale
    public let moduleDescription: String

    public init(locale: Locale, moduleDescription: String) {
        self.locale = locale
        self.moduleDescription = moduleDescription
    }
}
