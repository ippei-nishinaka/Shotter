import CoreGraphics
import Foundation
import Vision

/// OCR の結果。
struct RecognizedText {
    let lines: [String]

    var joined: String { lines.joined(separator: "\n") }
    var isEmpty: Bool { lines.isEmpty }
}

enum TextRecognitionError: LocalizedError {
    case noTextFound

    var errorDescription: String? {
        "文字を検出できませんでした。"
    }
}

/// Vision の `VNRecognizeTextRequest` による文字認識。日本語と英語に対応する。
enum TextRecognizer {

    /// 認識させる言語。先に書いたものが優先される。
    static let languages = ["ja-JP", "en-US"]

    static func recognize(in image: CGImage) async throws -> RecognizedText {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = languages

                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let observations = request.results ?? []
                    continuation.resume(
                        returning: RecognizedText(lines: readingOrderLines(from: observations))
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    /// 認識結果を読み順（上から下、同じ行は左から右）に並べ直す。
    ///
    /// Vision の座標は正規化済みで原点が左下なので、y が大きいほど上になる。
    private static func readingOrderLines(from observations: [VNRecognizedTextObservation]) -> [String] {
        let items: [(box: CGRect, text: String)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (observation.boundingBox, text)
        }
        guard !items.isEmpty else { return [] }

        // 縦に重なっているものは同じ行とみなす。
        var rows: [[(box: CGRect, text: String)]] = []
        for item in items.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let index = rows.indices.last, let last = rows[index].first,
               verticalOverlapRatio(last.box, item.box) > 0.5 {
                rows[index].append(item)
            } else {
                rows.append([item])
            }
        }

        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }
                .map(\.text)
                .joined(separator: " ")
        }
    }

    /// 2 つの矩形が縦方向にどれだけ重なっているか（0〜1）。
    private static func verticalOverlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap > 0 else { return 0 }
        return overlap / min(a.height, b.height)
    }
}
