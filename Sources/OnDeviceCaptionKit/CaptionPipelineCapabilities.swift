import Foundation
import Speech

public enum CaptionPipelineCapabilities {
    public static func preferredProvider(on _: ProcessInfo = .processInfo) -> CaptionRecognitionProviderID {
        if #available(macOS 26, *) {
            return ModernSpeechProvider.isRuntimeAvailable ? .modern : .legacy
        }
        return .legacy
    }

    public static func supportedTranscriptionLocales(on _: ProcessInfo = .processInfo) async -> [Locale] {
        var locales: [Locale] = []
        if #available(macOS 26, *) {
            locales.append(contentsOf: await ModernSpeechProvider.supportedLocales())
        }
        if SFSpeechRecognizer(locale: Locale(identifier: "en-US")) != nil {
            locales.append(Locale(identifier: "en-US"))
        }
        var seen = Set<String>()
        return locales.filter { locale in
            let key = locale.identifier
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    @available(macOS 26, *)
    public static func requiresAssetDownload(for locale: Locale) async -> CaptionAssetDownloadRequirement? {
        await ModernSpeechProvider.assetDownloadRequirement(for: locale)
    }
}
