import Foundation
import SwiftUI
import UIKit
import CoreImage

/// 错题本行预览的「带图摘要」:把题干 HTML 里的行内公式图(透明底线条稿)按行高
/// 缩放后原位内联进摘要文本,数字运算这类「与〔公式〕相加,其和的个位数字是
/// ( )。」的断句行不再突兀;块级图表不参与(留给详情页)。
///
/// 渲染侧用 SwiftUI 的 `Text` 拼接(`Text + Text(Image)`):换行/截断交给 Text,
/// 无 WebView。深色模式在**位图**上做反色(拼接进 Text 的图片吃不到
/// `.colorInvert()`,那是整视图修饰符),透明底必须保持。
enum FormulaInlinePreview {

    enum Segment: Equatable {
        case text(String)
        case image(url: String)
    }

    /// 组装结果:分段 + 可用位图(按 URL 去重)+ 文本全文(无障碍/兜底判空)。
    struct Composition {
        let segments: [Segment]
        let images: [String: UIImage]
        let plainText: String
        /// 实际画上去的图数(按出现次数,同图两处算两张)。
        let renderedImageCount: Int

        /// 题干里有没有图片段(即使本地库没有字节)。
        var hasImageSegments: Bool {
            segments.contains { if case .image = $0 { true } else { false } }
        }
    }

    /// 分段(纯函数):题干 HTML → 文本/图片按文档序交替。文本段逐段走
    /// `HTMLText.plainSummaryText`(与 summary 同一净化口径),无图题得到
    /// 恰好一个文本段、内容与今天的纯文本摘要逐字一致。
    nonisolated static func segments(of html: String) -> [Segment] {
        let spaced = html.replacingOccurrences(
            of: #"<br\s*/?>|</p>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let ns = spaced as NSString
        var segments: [Segment] = []
        func appendText(_ raw: String) {
            let text = HTMLText.plainSummaryText(from: raw)
            guard !text.isEmpty else { return }
            segments.append(.text(text))
        }
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else {
            // 与 summary 同口径:走同一条净化,而不是各写一份。
            let text = HTMLText.plainSummaryText(from: html)
            return text.isEmpty ? [] : [.text(text)]
        }
        var cursor = 0
        for match in regex.matches(in: spaced, range: NSRange(location: 0, length: ns.length)) {
            appendText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            // 复用题库的 src 抽取(实体解码 / // 前缀补全),单个 img 标签返回 0/1 个 URL。
            if let url = BankDatabase.imageURLs(from: ns.substring(with: match.range)).first {
                segments.append(.image(url: url))
            }
            cursor = match.range.location + match.range.length
        }
        appendText(ns.substring(from: cursor))
        return segments
    }

    /// 文本段拼接(无障碍朗读与「有没有可见文本」判定的口径)。
    nonisolated static func plainText(of segments: [Segment]) -> String {
        segments.reduce(into: "") { text, segment in
            if case .text(let piece) = segment { text += piece }
        }
    }

    /// 组装:分段 + 位图准备。图片在本地库没有字节时**跳过该位置**——行里
    /// 不放灰块,文本原样保留。
    @MainActor
    static func compose(html: String, database: BankDatabase?,
                        imageHeight: CGFloat, dark: Bool) -> Composition {
        let segments = Self.segments(of: html)
        var images: [String: UIImage] = [:]
        var renderedCount = 0
        for segment in segments {
            guard case .image(let url) = segment else { continue }
            if images[url] != nil {          // 同一张公式出现多次:位图复用,按次数计
                renderedCount += 1
                continue
            }
            guard let image = preparedImage(url: url, database: database, height: imageHeight, dark: dark) else {
                continue
            }
            images[url] = image
            renderedCount += 1
        }
        return Composition(segments: segments, images: images,
                           plainText: Self.plainText(of: segments),
                           renderedImageCount: renderedCount)
    }

    /// 行内容的无障碍标签:文本 + 含图提示(VoiceOver 知道点开有图;UI 测试
    /// 按这个标签断言行内公式确实画上去了)。
    nonisolated static func accessibilityLabel(for composition: Composition) -> String {
        guard composition.renderedImageCount > 0 else { return composition.plainText }
        let hint = "（含 \(composition.renderedImageCount) 张公式图）"
        return composition.plainText.isEmpty ? hint : composition.plainText + hint
    }

    /// 没有任何可见内容时的兜底文案;nil = 有内容。
    nonisolated static func fallbackText(for composition: Composition) -> String? {
        guard composition.plainText.isEmpty, composition.renderedImageCount == 0 else { return nil }
        return composition.hasImageSegments ? "（含图题目，点开查看）" : "（题干无文本）"
    }

    /// 行级无障碍标签:兜底文案优先(空内容时 VoiceOver 不能读到空串),
    /// 否则是 文本 + 含图提示。
    nonisolated static func rowAccessibilityLabel(for composition: Composition) -> String {
        fallbackText(for: composition) ?? accessibilityLabel(for: composition)
    }

    /// 行内公式图相对正文字号的高度比:15pt 正文 → 20pt 图(spike 实测最顺眼)。
    static let imageHeightRatio: CGFloat = 1.33

    // MARK: - 位图准备

    /// 解码(贵的那步)由 BankImageResolver 按库缓存,且随题库替换失效;这里
    /// 只做缩放(可能加反色)的小位图重绘,故意不再加一层静态缓存——静态缓存
    /// 跨库共享,换库后会拿旧库的位图充数(测试里不同内存库也会互相串)。
    @MainActor
    private static func preparedImage(url: String, database: BankDatabase?,
                                      height: CGFloat, dark: Bool) -> UIImage? {
        guard let database, height > 0 else { return nil }
        guard let source = database.resolverImage(for: url) else { return nil }
        // 反色只对线条稿(公式),与详情页同一判据:彩色图表反色就成了负片。
        let image = dark && database.isLineArtImage(url) ? (inverted(source) ?? source) : source
        let ratio = height / image.size.height
        let target = CGSize(width: image.size.width * ratio, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 位图反色,透明底保持(CIColorInvert 保留 alpha;不能用白底 difference
    /// 混合——透明区会被填成白块)。
    private nonisolated static func inverted(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage, let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let invertedCG = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: invertedCG, scale: image.scale, orientation: .up)
    }
}

/// 错题本行预览(SwiftUI 侧):把题干渲染成带图摘要,行的两行截断由 Text 自己
/// 完成;`Composition` 每次求值现算——解码由 resolver 按库缓存,缩放只是小图重绘。
struct FormulaInlineRowPreview: View {
    let html: String
    var fontSize: CGFloat = 15

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let composition = FormulaInlinePreview.compose(
            html: html,
            database: appState.bankDatabase,
            imageHeight: fontSize * FormulaInlinePreview.imageHeightRatio,
            dark: colorScheme == .dark
        )
        Group {
            if let fallback = FormulaInlinePreview.fallbackText(for: composition) {
                Text(fallback)
            } else {
                text(for: composition)
            }
        }
        .font(.system(size: fontSize))
        .lineLimit(2)
        .accessibilityLabel(FormulaInlinePreview.rowAccessibilityLabel(for: composition))
    }

    private func text(for composition: FormulaInlinePreview.Composition) -> Text {
        composition.segments.reduce(Text("")) { text, segment in
            switch segment {
            case .text(let piece):
                return text + Text(piece)
            case .image(let url):
                guard let image = composition.images[url] else { return text }
                return text + Text(Image(uiImage: image))
            }
        }
    }
}
