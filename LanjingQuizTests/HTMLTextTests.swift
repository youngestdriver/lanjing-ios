import XCTest
import SwiftUI
import UIKit
@testable import LanjingQuiz

final class HTMLTextTests: XCTestCase {

    func testCanFastRenderWhitelist() {
        XCTAssertTrue(HTMLText.canFastRender("<p>甲</p><p>乙</p>"))
        XCTAssertTrue(HTMLText.canFastRender(#"<p><span style="font-size: 16px; line-height: 32px">甲</span></p>"#))
        XCTAssertTrue(HTMLText.canFastRender("<p><strong>甲</strong><br/>乙</p>"))
        XCTAssertFalse(HTMLText.canFastRender("<ul><li>列表</li></ul>"))
        XCTAssertFalse(HTMLText.canFastRender("<p>x<sup>2</sup></p>"))
        XCTAssertFalse(HTMLText.canFastRender("<p>有图<img src=\"https://x/y.png\"></p>"))
        XCTAssertFalse(HTMLText.canFastRender("<h3>标题</h3>"))
    }

    @MainActor
    func testFastRenderTextAndParagraphs() throws {
        let rendered = try XCTUnwrap(HTMLText.render("<p>甲</p><p>乙</p>", dark: false))
        XCTAssertEqual(String(rendered.characters), "甲\n\n乙")
    }

    @MainActor
    func testFastRenderHonorsFontSizeAndLineHeight() throws {
        let html = #"<p><span style="font-size: 16px; line-height: 32px;">样式</span></p>"#
        let rendered = try XCTUnwrap(HTMLText.render(html, dark: false))
        let runs = rendered.runs
        let first = try XCTUnwrap(runs.first)
        let font = first.uiKit.font
        XCTAssertEqual(font?.pointSize, 16, "span 字号必须被解析")
        if let paragraph = first.uiKit.paragraphStyle {
            XCTAssertEqual(paragraph.minimumLineHeight, 32, "line-height 必须作用于段落")
            XCTAssertEqual(paragraph.maximumLineHeight, 32)
        }
    }

    @MainActor
    func testFastRenderBoldAndDarkForeground() throws {
        let bold = try XCTUnwrap(HTMLText.render("<p><strong>加粗</strong></p>", dark: false))
        let trait = try XCTUnwrap(bold.runs.first?.uiKit.font)
        XCTAssertTrue(trait.fontDescriptor.symbolicTraits.contains(.traitBold), "strong 必须加粗")

        let dark = try XCTUnwrap(HTMLText.render("<p>正文</p>", dark: true))
        XCTAssertEqual(dark.runs.first?.uiKit.foregroundColor, .white, "dark 模式前景必须统一为白")
    }

    @MainActor
    func testFastRenderEntitiesAndBr() throws {
        // 输入里 &nbsp; 前后自带空格,保留原样(空格 + NBSP + 空格)。
        let html = "<p>甲<br/>乙 &amp; 丙 &nbsp; 丁</p>"
        let rendered = try XCTUnwrap(HTMLText.render(html, dark: false))
        XCTAssertEqual(String(rendered.characters), "甲\n乙 & 丙 \u{00A0} 丁")
    }

    @MainActor
    func testFastRenderRestoresStyleAfterSpanClose() throws {
        let html = #"<p>前缀<span style="font-size: 14px;">小</span>后再大<span style="font-size: 20px;">大</span></p>"#
        let rendered = try XCTUnwrap(HTMLText.render(html, dark: false))
        let runs = Array(rendered.runs)
        let sizes = runs.map { $0.uiKit.font?.pointSize }
        XCTAssertEqual(String(rendered.characters), "前缀小后再大大")
        // 前缀(17)与恢复后的正文(17)不能并进 14/20 的 run。
        XCTAssertEqual(sizes.first, 17, "span 外文本保持默认字号")
        XCTAssertEqual(sizes.contains(14), true, "span 打开时应用指定字号")
        XCTAssertEqual(sizes.contains(17), true, "span 关闭后应恢复默认字号")
        XCTAssertEqual(sizes.contains(20), true, "span 打开时应用指定字号")
    }

    @MainActor
    func testFallsBackToImporterForComplexTags() throws {
        let rendered = try XCTUnwrap(HTMLText.render("<ul><li>列表项</li></ul>", dark: false))
        XCTAssertTrue(String(rendered.characters).contains("列表项"))
    }
    // MARK: - 摘要提取(错题本列表行)

    func testSummaryStripsTagsDecodesEntitiesAndCollapsesWhitespace() {
        // 真实题库大量 &nbsp;:plainText 只剥标签不解实体,摘要必须解完再压空白。
        XCTAssertEqual(HTMLText.summary(from: "<p>甲&nbsp;&nbsp;乙</p><p>丙\t丁</p>"), "甲 乙 丙 丁")
        XCTAssertEqual(HTMLText.summary(from: "<p>他说&ldquo;好&rdquo; &amp; 走了</p>"), "他说“好” & 走了")
        XCTAssertEqual(HTMLText.summary(from: "<p>&#39;单引号&#39;</p>"), "'单引号'")
        // <br> 是块边界,先补空格避免前后文字粘在一起。
        XCTAssertEqual(HTMLText.summary(from: "<p>有图<br/>换行</p>"), "有图 换行")
    }

    func testSummaryTruncatesByCharacterAndAppendsEllipsis() {
        XCTAssertEqual(HTMLText.summary(from: "<p>一二三四五六七八九十</p>", limit: 4), "一二三四…")
        XCTAssertEqual(HTMLText.summary(from: "<p>一二三四五六七八九十</p>", limit: 10), "一二三四五六七八九十")
        // 按 Character(字素簇)截断:家庭 emoji 是单个 Character,不能被切进 ZWJ 序列。
        XCTAssertEqual(HTMLText.summary(from: "<p>👨‍👩‍👧‍👦甲乙丙</p>", limit: 2), "👨‍👩‍👧‍👦甲…")
        // 默认 limit = 80(超限补「…」→ 81 个 Character)。
        XCTAssertEqual(HTMLText.summary(from: "<p>" + String(repeating: "题", count: 100) + "</p>").count, 81)
    }
}
