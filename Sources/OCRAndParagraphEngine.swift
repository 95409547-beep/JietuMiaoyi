import Cocoa
import Vision

/// 识别并聚合后的原位文本块（采用左上角为原点的归一化坐标 [0, 1]）
struct RecognizedTextBlock {
    /// 左上角为原点的归一化矩形（x, y, width, height 均在 0...1 之间）
    var normalizedTopLeftRect: CGRect
    /// 合并后的原文
    var originalText: String
    /// 该块包含的原始行数（用于推算最自然的字号）
    var lineCount: Int
    /// 翻译后的文本
    var translatedText: String = ""
}

enum OCRAndParagraphEngine {

    /// 默认采用 0.15s 毫秒级极速识别（避免 macOS 神经引擎冷启动 60s 阻塞）；可在菜单栏按需切换高精度模式
    static var useAccurateMode: Bool {
        get { UserDefaults.standard.bool(forKey: "ocr_use_accurate_mode") }
        set { UserDefaults.standard.set(newValue, forKey: "ocr_use_accurate_mode") }
    }

    static func warmUpInBackground() {
        // 无需后台预热 .accurate，避免占用全局 Vision 锁阻塞用户首次框选
    }

    /// 使用 macOS 原生 Vision 框架离线高速识别图片文字，并将同段落折行智能聚合
    static func recognizeBlocks(in cgImage: CGImage) async throws -> [RecognizedTextBlock] {
        let accurate = Self.useAccurateMode
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                if accurate {
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true
                } else {
                    request.recognitionLevel = .fast
                    request.usesLanguageCorrection = true
                }

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    let blocks = Self.mergeObservationsIntoBlocks(observations)
                    continuation.resume(returning: blocks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 将单行 OCR 结果聚合成自然语义段落，既保证翻译上下文完整，又保留独立按钮/标题的原位坐标
    private static func mergeObservationsIntoBlocks(_ observations: [VNRecognizedTextObservation]) -> [RecognizedTextBlock] {
        struct RawLine {
            let rect: CGRect // 左上角原点归一化坐标
            let text: String
        }

        var rawLines: [RawLine] = []
        for obs in observations {
            guard let topCandidate = obs.topCandidates(1).first else { continue }
            let trimmed = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let bbox = obs.boundingBox
            // Vision 原点在左下角，转换为左上角原点归一化坐标
            let topLeftRect = CGRect(
                x: bbox.origin.x,
                y: 1.0 - bbox.origin.y - bbox.height,
                width: bbox.width,
                height: bbox.height
            )
            rawLines.append(RawLine(rect: topLeftRect, text: trimmed))
        }

        guard !rawLines.isEmpty else { return [] }

        // 按从上到下、从左到右排序
        rawLines.sort { a, b in
            if abs(a.rect.minY - b.rect.minY) > min(a.rect.height, b.rect.height) * 0.45 {
                return a.rect.minY < b.rect.minY
            }
            return a.rect.minX < b.rect.minX
        }

        // 第一步：合并同一水平行上紧邻拆碎的词块
        var mergedHorizontalLines: [RawLine] = []
        for line in rawLines {
            if let last = mergedHorizontalLines.last {
                let minH = min(last.rect.height, line.rect.height)
                let maxH = max(last.rect.height, line.rect.height)
                let verticalOverlap = min(last.rect.maxY, line.rect.maxY) - max(last.rect.minY, line.rect.minY)
                let horizontalGap = line.rect.minX - last.rect.maxX

                if verticalOverlap > minH * 0.55 && maxH / max(minH, 0.0001) < 1.45 && horizontalGap >= -minH * 0.5 && horizontalGap < minH * 1.6 {
                    let unionRect = last.rect.union(line.rect)
                    let joined = joinInlineText(last.text, line.text)
                    mergedHorizontalLines[mergedHorizontalLines.count - 1] = RawLine(rect: unionRect, text: joined)
                    continue
                }
            }
            mergedHorizontalLines.append(line)
        }

        // 第二步：合并同一自然段落的连续上下行
        var blocks: [RecognizedTextBlock] = []
        for line in mergedHorizontalLines {
            if var lastBlock = blocks.last {
                let avgLineHeight = lastBlock.normalizedTopLeftRect.height / CGFloat(max(lastBlock.lineCount, 1))
                let heightRatio = max(avgLineHeight, line.rect.height) / max(min(avgLineHeight, line.rect.height), 0.0001)
                let verticalGap = line.rect.minY - lastBlock.normalizedTopLeftRect.maxY

                let overlapX = min(lastBlock.normalizedTopLeftRect.maxX, line.rect.maxX) - max(lastBlock.normalizedTopLeftRect.minX, line.rect.minX)
                let minWidth = min(lastBlock.normalizedTopLeftRect.width, line.rect.width)
                let leftDiff = abs(lastBlock.normalizedTopLeftRect.minX - line.rect.minX)

                // 判断是否属于同一自然段落：字号相近、上下行紧邻、左边缘基本对齐且水平有明显交集
                let isSameParagraph =
                    heightRatio < 1.38 &&
                    verticalGap >= -avgLineHeight * 0.35 &&
                    verticalGap < avgLineHeight * 0.72 &&
                    overlapX > minWidth * 0.35 &&
                    leftDiff < avgLineHeight * 2.5

                if isSameParagraph {
                    lastBlock.normalizedTopLeftRect = lastBlock.normalizedTopLeftRect.union(line.rect)
                    lastBlock.originalText = joinParagraphLines(lastBlock.originalText, line.text)
                    lastBlock.lineCount += 1
                    blocks[blocks.count - 1] = lastBlock
                    continue
                }
            }

            blocks.append(
                RecognizedTextBlock(
                    normalizedTopLeftRect: line.rect,
                    originalText: line.text,
                    lineCount: 1
                )
            )
        }

        return blocks
    }

    private static func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) {
                return true
            }
        }
        return false
    }

    private static func joinInlineText(_ a: String, _ b: String) -> String {
        if containsCJK(a) && containsCJK(b) {
            return a + b
        }
        return a + " " + b
    }

    private static func joinParagraphLines(_ a: String, _ b: String) -> String {
        if a.hasSuffix("-") && a.count > 1 {
            return String(a.dropLast()) + b
        }
        if containsCJK(a) && containsCJK(b) {
            return a + b
        }
        return a + " " + b
    }
}
