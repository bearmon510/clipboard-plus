import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Minimal wrapper around AzooKeyKanaKanjiConverter for the keyboard extension target.
/// Dictionary loading stays lazy (`preloadDictionary: false`) to respect extension memory limits.
@MainActor
final class JapaneseConversionEngine {
    private lazy var converter = KanaKanjiConverter.withDefaultDictionary()

    /// Converts a hiragana reading into candidate strings without writing persistent learning state.
    func convert(
        hiragana: String,
        maxResults: Int = 10,
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String] {
        guard !hiragana.isEmpty else { return [] }
        var composing = ComposingText()
        composing.insertAtCursorPosition(hiragana, inputStyle: .direct)
        let options = ConvertRequestOptions(
            N_best: maxResults,
            needTypoCorrection: false,
            requireJapanesePrediction: true,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: scratchDirectory,
            sharedContainerURL: scratchDirectory,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: nil
        )
        return converter.requestCandidates(composing, options: options).mainResults.map(\.text)
    }
}
