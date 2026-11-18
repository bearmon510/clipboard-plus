import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

final class JapaneseConversionTests: XCTestCase {
    func testConvertKanjiReadingIncludesKanjiCandidate() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("japanese-conversion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let converter = KanaKanjiConverter.withDefaultDictionary()
        var composing = ComposingText()
        composing.insertAtCursorPosition("かんじ", inputStyle: .direct)

        let options = ConvertRequestOptions(
            N_best: 10,
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
            memoryDirectoryURL: tempDir,
            sharedContainerURL: tempDir,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: nil
        )

        let result = converter.requestCandidates(composing, options: options)
        let texts = result.mainResults.map(\.text)
        XCTAssertTrue(texts.contains("漢字"), "Expected '漢字' in candidates for 'かんじ', got: \(texts)")
    }
}
