import CoreGraphics
import Foundation
import Vision

/// One piece of text found in a picture. `box` is in unit space, origin top-left.
struct RecognizedLine: Equatable {
    let text: String
    let box: CGRect
}

enum TextRecognizerError: Error {
    case noImage
}

/// Reads text in a picture on the device with Vision. Nothing leaves the device.
enum TextRecognizer {
    /// Blocks while Vision works. Call it off the main thread.
    static func lines(in image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision's origin is bottom-left; the rest of the app uses top-left.
            let box = observation.boundingBox
            return RecognizedLine(text: candidate.string,
                                  box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
    }

    static func text(in image: CGImage) throws -> String {
        assemble(try lines(in: image))
    }

    /// Joins the pieces in reading order: rows from top to bottom, and left to right inside a row.
    /// Two pieces share a row when the middle of one lies within the height of the other.
    static func assemble(_ lines: [RecognizedLine]) -> String {
        let sorted = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.box.midY < $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let last = rows.last, let reference = last.first,
               line.box.midY >= reference.box.minY, line.box.midY <= reference.box.maxY {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows
            .map { row in row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
