import XCTest
@testable import HighlightSwift

/// The attributed string is built from highlight.js's markup and the
/// stylesheet's rules directly: each run takes the colour of the innermost
/// element a rule reaches, its ancestors' otherwise, the root's last, with
/// the cascade's specificity and order among the rules that reach it.
final class HighlightMarkupTests: XCTestCase {
    /// The runs of an attributed string as text and colour hex, nil for a
    /// run without a colour.
    private func runs(_ text: AttributedString) -> [(String, String?)] {
        let string = NSAttributedString(text)
        var runs: [(String, String?)] = []
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            let color = attributes[.foregroundColor] as? HighlightPlatformColor
            runs.append((string.attributedSubstring(from: range).string, color.map(hex)))
        }
        return runs
    }

    private func hex(_ color: HighlightPlatformColor) -> String {
#if canImport(AppKit)
        let color = color.usingColorSpace(.sRGB) ?? color
#endif
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    func testARunTakesItsElementsRuleAndBareTextTheRootsColour() {
        let text = HighlightMarkup.attributedString(
            #"<span class="hljs-keyword">let</span> x = &quot;a&quot; &amp;&lt;&gt;&#x27;&#65;"#,
            css: ".hljs{color:#112233}.hljs-keyword{color:#ff0000}")
        XCTAssertEqual(runs(text).map(\.0), ["let", " x = \"a\" &<>'A"])
        XCTAssertEqual(runs(text).map(\.1), ["#ff0000", "#112233"])
    }

    func testCompoundAndDescendantSelectorsOutrankOneClassAndOrderBreaksTies() {
        let css = ".hljs-title{color:#010101}.hljs-title.class_{color:#020202}"
            + ".hljs-meta .hljs-string{color:#030303}.hljs-string{color:#040404}"
            + ".hljs-number{color:#050505}.hljs-number{color:#060606}"
        let text = HighlightMarkup.attributedString(
            #"<span class="hljs-title class_">A</span><span class="hljs-meta"><span class="hljs-string">s</span></span><span class="hljs-string">t</span><span class="hljs-number">1</span>"#,
            css: css)
        XCTAssertEqual(runs(text).map(\.1), ["#020202", "#030303", "#040404", "#060606"])
    }

    func testAnElementNoRuleReachesInheritsItsParent() {
        let text = HighlightMarkup.attributedString(
            #"<span class="hljs-meta">#<span class="hljs-keyword">if</span> DEBUG</span> tail"#,
            css: ".hljs-meta{color:#0a0a0a}")
        XCTAssertEqual(runs(text).map(\.0), ["#if DEBUG", " tail"])
        XCTAssertEqual(runs(text).map(\.1), ["#0a0a0a", nil])
    }

    func testTheEndsAreTrimmedAndTheInsideIsKept() {
        let text = HighlightMarkup.attributedString("\n  <span class=\"hljs-keyword\">a</span>\n\tb  \n\n", css: "")
        XCTAssertEqual(String(text.characters), "a\n\tb")
    }

    func testCommentsAtRulesImportantAndNamedColoursParse() {
        let css = """
        /* a theme */
        @media (forced-colors: active) { .hljs-comment { color: #111111 } }
        .hljs-comment, .hljs-quote { color: silver !important; font-style: italic }
        .hljs-link { text-decoration: underline; color: rgb(0, 0, 255) }
        pre code.hljs { padding: 1em }
        .hljs ::selection { background: #fff }
        """
        let text = HighlightMarkup.attributedString(
            #"<span class="hljs-comment">c</span><span class="hljs-link">l</span>"#, css: css)
        XCTAssertEqual(runs(text).map(\.1), ["#c0c0c0", "#0000ff"])
        let string = NSAttributedString(text)
        XCTAssertNil(string.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(string.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(string.attribute(.font, at: 0, effectiveRange: nil))
    }

    func testAHighlightCarriesTheThemesColoursAndNoFont() throws {
        let result = try Highlight().requestSync("\nlet x = 1\n", mode: .language(.swift), colors: .light(.xcode))
        XCTAssertFalse(result.isUndefined)
        let string = NSAttributedString(result.attributedText)
        XCTAssertEqual(string.string, "let x = 1")
        XCTAssertEqual(hex(try XCTUnwrap(string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? HighlightPlatformColor)), "#aa0d91")
        XCTAssertEqual(hex(try XCTUnwrap(string.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? HighlightPlatformColor)), "#000000")
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { font, _, _ in
            XCTAssertNil(font)
        }
    }
}
