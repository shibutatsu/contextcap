import AppKit
import Vision

public enum ImageRecognizer {
    /// Runs locally, off the main actor. The caller checks its session before committing.
    public static func recognize(_ image: CGImage) throws -> (Data, String) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ArchiveError.invalidRecord
        }
        return (data, text)
    }
}
