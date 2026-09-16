import XCTest
import SwiftData
import UIKit
@testable import LanjingQuiz

/// FormulaInlinePreview 单测:错题本行预览的「带图摘要」——分段、公式位图准备
/// (按行高缩放、深色反色、透明底保持)与兜底/无障碍文案。
/// 图片用代码生成的 PNG 走内存库,不碰磁盘;公式端点 URL 使 isLineArt 判定确定。
@MainActor
final class FormulaInlinePreviewTests: XCTestCase {

    /// 上游公式端点(contains "/accessories/formulas?")——isLineArt 恒真,
    /// 与图片像素无关,测试只关心外形的判定不被这里的不确定性污染。
    private let formulaURL = "https://fb.fenbike.cn/api/planet/accessories/formulas?latex=abc&fontSize=18"

    // MARK: - 图片素材(代码生成 PNG)

    /// 透明底 + 深灰方块,200×40(scale 1):模拟公式线条稿。
    private func lineArtPNGData() -> Data {
        let size = CGSize(width: 200, height: 40)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(UIColor(white: 0.16, alpha: 1).cgColor)
            context.cgContext.fill(CGRect(x: 8, y: 8, width: 184, height: 24))
        }
        return image.pngData()!
    }

    /// 白底 + 彩色块:模拟照片/图表(非线条稿)。
    private func coloredPNGData() -> Data {
        let size = CGSize(width: 200, height: 40)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            context.cgContext.setFillColor(UIColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1).cgColor)
            context.cgContext.fill(CGRect(x: 8, y: 8, width: 184, height: 24))
        }
        return image.pngData()!
    }

    private func makeDatabase(_ images: [(url: String, data: Data)]) -> BankDatabase {
        let database = try! BankDatabase(inMemory: true)
        let context = ModelContext(database.container)
        for (url, data) in images {
            context.insert(BankImage(id: Hashing.sha256Hex(url), remoteURL: url, data: data))
        }
        try! context.save()
        return database
    }

    // MARK: - 像素采样

    private func pixel(of image: UIImage, at point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let cg = image.cgImage!
        let x = Int(point.x * CGFloat(cg.width) / image.size.width)
        let y = Int(point.y * CGFloat(cg.height) / image.size.height)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255, CGFloat(bytes[3]) / 255)
    }

    private func luminance(_ pixel: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> CGFloat {
        pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114
    }

    // MARK: - 分段

    /// 行内公式:文本/图片按文档序交替;文本段与 HTMLText.summary 同一净化口径。
    func testSegmentsInterleaveTextAndInlineImages() {
        let html = #"<p>计算<img src="\#(formulaURL)">的结果为（ ）。</p>"#
        XCTAssertEqual(FormulaInlinePreview.segments(of: html), [
            .text("计算"),
            .image(url: formulaURL),
            .text("的结果为（ ）。"),
        ])
    }

    /// 整段只有图(块级图表):得到一个纯图片段,不产出空文本段。
    func testSegmentsBlockOnlyImageYieldsSingleImageSegment() {
        let html = #"<p><img src="\#(formulaURL)"/></p>"#
        XCTAssertEqual(FormulaInlinePreview.segments(of: html), [.image(url: formulaURL)])
    }

    /// 实体转义(&amp;)的 src 解码后与未转义写法一致(与 BankDatabase.imageURLs 同口径)。
    func testSegmentsDecodeEscapedImageURL() {
        let escaped = formulaURL.replacingOccurrences(of: "&", with: "&amp;")
        let html = #"<p>计算<img src="\#(escaped)">的结果</p>"#
        XCTAssertEqual(FormulaInlinePreview.segments(of: html), [
            .text("计算"), .image(url: formulaURL), .text("的结果"),
        ])
    }

    /// 无图 HTML:全部落在一个文本段,内容与 HTMLText.summary 完全一致
    /// (无图行必须与今天的纯文本摘要逐字相同)。
    func testSegmentsTextOnlyMatchesSummary() {
        let html = "<p>依次填入最恰当的一项是</p>"
        let segments = FormulaInlinePreview.segments(of: html)
        XCTAssertEqual(segments, [.text("依次填入最恰当的一项是")])
        XCTAssertEqual(FormulaInlinePreview.plainText(of: segments), HTMLText.summary(from: html))
    }

    // MARK: - 组装(位图准备)

    /// 公式图按目标行高等比缩放(200×40 → 高 20 → 100×20)。
    func testComposeScalesFormulaImageToRequestedHeight() throws {
        let database = makeDatabase([(formulaURL, lineArtPNGData())])
        let html = #"<p>计算<img src="\#(formulaURL)">的结果为（ ）。</p>"#
        let composition = FormulaInlinePreview.compose(html: html, database: database,
                                                       imageHeight: 20, dark: false)
        XCTAssertEqual(composition.renderedImageCount, 1)
        XCTAssertEqual(composition.plainText, "计算的结果为（ ）。")
        let image = try XCTUnwrap(composition.images[formulaURL])
        XCTAssertEqual(image.size.height, 20, accuracy: 0.01)
        XCTAssertEqual(image.size.width, 100, accuracy: 0.5)
    }

    /// 深色模式:线条稿公式反色(深灰笔画 → 亮),透明底保持(角落 alpha 0);
    /// 浅色模式:原样不反色。
    func testComposeInvertsLineArtInDarkModeKeepingTransparency() throws {
        let database = makeDatabase([(formulaURL, lineArtPNGData())])
        let html = #"<p>计算<img src="\#(formulaURL)">的结果</p>"#
        let light = FormulaInlinePreview.compose(html: html, database: database,
                                                 imageHeight: 20, dark: false)
        let dark = FormulaInlinePreview.compose(html: html, database: database,
                                                imageHeight: 20, dark: true)
        let lightImage = try XCTUnwrap(light.images[formulaURL])
        let darkImage = try XCTUnwrap(dark.images[formulaURL])

        let lightStroke = pixel(of: lightImage, at: CGPoint(x: 50, y: 10))
        let darkStroke = pixel(of: darkImage, at: CGPoint(x: 50, y: 10))
        XCTAssertLessThan(luminance(lightStroke), 0.4, "浅色模式线条稿应保持深色笔画")
        XCTAssertGreaterThan(luminance(darkStroke), 0.6, "深色模式线条稿应反色成亮笔画")

        XCTAssertEqual(pixel(of: lightImage, at: CGPoint(x: 2, y: 2)).a, 0, accuracy: 0.01, "透明底不得被填白")
        XCTAssertEqual(pixel(of: darkImage, at: CGPoint(x: 2, y: 2)).a, 0, accuracy: 0.01, "反色后透明底必须保持")
    }

    /// 非线条稿(彩色照片/图表)在任何外观下都不反色。
    func testComposeLeavesNonLineArtUninvertedInDarkMode() throws {
        let photoURL = "https://fb.fbstatic.cn/api/planet/accessories/attachments/photo1"
        let database = makeDatabase([(photoURL, coloredPNGData())])
        let html = #"<p>如图<img src="\#(photoURL)">所示</p>"#
        let dark = FormulaInlinePreview.compose(html: html, database: database,
                                                imageHeight: 20, dark: true)
        let image = try XCTUnwrap(dark.images[photoURL])
        let stroke = pixel(of: image, at: CGPoint(x: 50, y: 10))
        XCTAssertGreaterThan(stroke.r, 0.6, "彩色图不反色:红通道应保持高")
        XCTAssertLessThan(stroke.g, 0.4, "彩色图不反色:绿通道应保持低")
    }

    /// 本地库没有这张图的字节(或没有库):该位置不插图,文本不受影响——
    /// 行里绝不出现灰块。
    func testComposeSkipsImagesWithoutLocalBytes() {
        let database = makeDatabase([])
        let html = #"<p>计算<img src="\#(formulaURL)">的结果为（ ）。</p>"#
        let composition = FormulaInlinePreview.compose(html: html, database: database,
                                                       imageHeight: 20, dark: false)
        XCTAssertEqual(composition.renderedImageCount, 0)
        XCTAssertTrue(composition.images.isEmpty)
        XCTAssertEqual(composition.plainText, "计算的结果为（ ）。")

        let noDatabase = FormulaInlinePreview.compose(html: html, database: nil,
                                                      imageHeight: 20, dark: false)
        XCTAssertEqual(noDatabase.renderedImageCount, 0)
        XCTAssertEqual(noDatabase.plainText, "计算的结果为（ ）。")
    }

    /// 同一张公式出现两次:两处都要画(count 按出现次数),位图只解一份。
    func testComposeCountsRepeatedImagePerOccurrence() {
        let database = makeDatabase([(formulaURL, lineArtPNGData())])
        let html = #"<p>已知<img src="\#(formulaURL)">，那么<img src="\#(formulaURL)">的值为（ ）。</p>"#
        let composition = FormulaInlinePreview.compose(html: html, database: database,
                                                       imageHeight: 20, dark: false)
        XCTAssertEqual(composition.renderedImageCount, 2)
        XCTAssertEqual(composition.images.count, 1)
    }

    // MARK: - 无障碍标签与兜底

    func testAccessibilityLabelAppendsImageHintOnlyWhenImagesRendered() throws {
        let database = makeDatabase([(formulaURL, lineArtPNGData())])
        let withImage = FormulaInlinePreview.compose(
            html: #"<p>计算<img src="\#(formulaURL)">的结果</p>"#,
            database: database, imageHeight: 20, dark: false
        )
        XCTAssertEqual(FormulaInlinePreview.accessibilityLabel(for: withImage), "计算的结果（含 1 张公式图）")

        let textOnly = FormulaInlinePreview.compose(
            html: "<p>依次填入最恰当的一项是</p>", database: database, imageHeight: 20, dark: false
        )
        XCTAssertEqual(FormulaInlinePreview.accessibilityLabel(for: textOnly), "依次填入最恰当的一项是")
    }

    /// 行级无障碍标签:空内容时用兜底文案,不然 VoiceOver 读到的就是空串。
    func testRowAccessibilityLabelUsesFallbackWhenNothingToShow() {
        let emptyDatabase = makeDatabase([])
        let empty = FormulaInlinePreview.compose(
            html: "<p>   </p>", database: emptyDatabase, imageHeight: 20, dark: false
        )
        XCTAssertEqual(FormulaInlinePreview.rowAccessibilityLabel(for: empty), "（题干无文本）")

        let imageMissing = FormulaInlinePreview.compose(
            html: #"<p><img src="\#(formulaURL)"/></p>"#, database: emptyDatabase, imageHeight: 20, dark: false
        )
        XCTAssertEqual(FormulaInlinePreview.rowAccessibilityLabel(for: imageMissing), "（含图题目，点开查看）")

        let withImage = FormulaInlinePreview.compose(
            html: #"<p>计算<img src="\#(formulaURL)">的结果</p>"#,
            database: makeDatabase([(formulaURL, lineArtPNGData())]), imageHeight: 20, dark: false
        )
        XCTAssertEqual(FormulaInlinePreview.rowAccessibilityLabel(for: withImage), "计算的结果（含 1 张公式图）")
    }

    func testFallbackTextOnlyWhenNothingToShow() throws {
        let database = makeDatabase([(formulaURL, lineArtPNGData())])
        let textOnly = FormulaInlinePreview.compose(
            html: "<p>依次填入最恰当的一项是</p>", database: database, imageHeight: 20, dark: false
        )
        XCTAssertNil(FormulaInlinePreview.fallbackText(for: textOnly), "有文本内容不需要兜底")

        // 纯图题且图可用:照样有内容,不兜底。
        let imageOnly = FormulaInlinePreview.compose(
            html: #"<p><img src="\#(formulaURL)"/></p>"#, database: database, imageHeight: 20, dark: false
        )
        XCTAssertEqual(imageOnly.renderedImageCount, 1)
        XCTAssertNil(FormulaInlinePreview.fallbackText(for: imageOnly))

        // 纯图题但本地没有字节:给「含图题目」提示,而不是空白/灰块。
        let imageMissing = FormulaInlinePreview.compose(
            html: #"<p><img src="\#(formulaURL)"/></p>"#, database: makeDatabase([]), imageHeight: 20, dark: false
        )
        XCTAssertEqual(FormulaInlinePreview.fallbackText(for: imageMissing), "（含图题目，点开查看）")

        // 既无文本也无图(上游就是空题干):沿用今天的「（题干无文本）」。
        let empty = FormulaInlinePreview.compose(
            html: "<p>   </p>", database: database, imageHeight: 20, dark: false
        )
        XCTAssertEqual(FormulaInlinePreview.fallbackText(for: empty), "（题干无文本）")
    }
}
