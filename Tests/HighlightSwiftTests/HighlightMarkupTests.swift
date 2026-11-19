import JavaScriptCore
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

    private func rgbaHex(_ color: HighlightPlatformColor) -> String {
#if canImport(AppKit)
        let color = color.usingColorSpace(.sRGB) ?? color
#endif
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02x%02x%02x%02x",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
            Int((alpha * 255).rounded())
        )
    }

    private func assertRunInvariants(
        text: String,
        runs: [HighlightRun],
        attributed: AttributedString,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let nsAttributed = NSAttributedString(attributed)
        XCTAssertEqual(text, nsAttributed.string, file: file, line: line)
        XCTAssertEqual(runs.map(\.text).joined(), text, file: file, line: line)

        var expectedUTF16 = 0
        for (index, run) in runs.enumerated() {
            XCTAssertFalse(run.text.isEmpty, "Empty run at \(index)", file: file, line: line)
            XCTAssertEqual(run.utf16Range.lowerBound, expectedUTF16, file: file, line: line)
            XCTAssertEqual(run.utf16Range.count, run.text.utf16.count, file: file, line: line)
            expectedUTF16 = run.utf16Range.upperBound
            if index > 0 {
                let previous = runs[index - 1]
                XCTAssertTrue(
                    previous.foregroundColor != run.foregroundColor || previous.isUnderlined != run.isUnderlined,
                    "Adjacent runs \(index - 1) and \(index) were not coalesced",
                    file: file,
                    line: line
                )
            }
        }
        XCTAssertEqual(expectedUTF16, text.utf16.count, file: file, line: line)
        XCTAssertEqual(expectedUTF16, nsAttributed.length, file: file, line: line)

        var attributedRuns: [(range: NSRange, text: String, color: String?, underlined: Bool)] = []
        nsAttributed.enumerateAttributes(in: NSRange(location: 0, length: nsAttributed.length)) { attributes, range, _ in
            XCTAssertNil(attributes[.font], file: file, line: line)
            let color = (attributes[.foregroundColor] as? HighlightPlatformColor).map(rgbaHex)
            let underlined = (attributes[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue
            attributedRuns.append((range, nsAttributed.attributedSubstring(from: range).string, color, underlined))
        }
        XCTAssertEqual(runs.count, attributedRuns.count, file: file, line: line)
        for (run, expected) in zip(runs, attributedRuns) {
            XCTAssertEqual(NSRange(run.utf16Range), expected.range, file: file, line: line)
            XCTAssertEqual(run.text, expected.text, file: file, line: line)
            XCTAssertEqual(run.foregroundColor.map(rgbaHex), expected.color, file: file, line: line)
            XCTAssertEqual(run.isUnderlined, expected.underlined, file: file, line: line)
        }
    }

    private func assertRequestParity(
        _ code: String,
        mode: HighlightMode,
        colors: HighlightColors,
        highlighter: Highlight = Highlight(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HighlightRunsResult {
        let runsResult = try highlighter.requestRunsSync(code, mode: mode, colors: colors)
        let syncResult = try highlighter.requestSync(code, mode: mode, colors: colors)
        XCTAssertEqual(runsResult.isUndefined, syncResult.isUndefined, file: file, line: line)
        XCTAssertEqual(runsResult.hasIllegal, syncResult.hasIllegal, file: file, line: line)
        XCTAssertEqual(runsResult.language, syncResult.language, file: file, line: line)
        XCTAssertEqual(runsResult.relevance, syncResult.relevance, file: file, line: line)
        XCTAssertEqual(runsResult.languageName, syncResult.languageName, file: file, line: line)
        XCTAssertEqual(runsResult.backgroundColor, syncResult.backgroundColor, file: file, line: line)
        XCTAssertEqual(runsResult.backgroundColorHex, colors.background, file: file, line: line)
        XCTAssertEqual(runsResult.mode, mode, file: file, line: line)
        assertRunInvariants(
            text: runsResult.text,
            runs: runsResult.runs,
            attributed: syncResult.attributedText,
            file: file,
            line: line
        )
        return runsResult
    }

    func testTokenizeParityCoversEntitiesEmptyWhitespaceUnicodeCRLFAndCascade() {
        let css = """
        /* cascade + underline */
        @media screen { .hljs-keyword { color: #999999 } }
        .hljs { color: #112233 }
        .hljs-keyword { color: #aa0d91 !important }
        .hljs-title { color: #010101 }
        .hljs-title.class_ { color: #020202 }
        .hljs-title>.hljs-built_in { color: teal }
        .hljs-built_in { color: #050505 }
        .hljs-meta .hljs-string { color: #030303 }
        .hljs-string { color: #040404 }
        .hljs-link { text-decoration: underline; color: rgb(0, 0, 255) }
        .hljs-under { text-decoration-line: underline; color: rgba(16, 32, 48, 0.5) }
        .hljs-tie { color: #101010 }
        .hljs-tie { color: #202020 }
        """
        let stylesheet = HighlightStylesheet(css: css)
        let cases: [(markup: String, expectedText: String)] = [
            ("", ""),
            ("   \t\r\n  ", ""),
            ("\u{00A0} \t\u{2028}", ""),
            ("\u{200B}<span class=\"hljs-keyword\">z</span>\u{200B}", "z"),
            ("<span></span>", ""),
            (
                #"<span class="hljs-keyword">let</span> x = &quot;a&quot; &amp;&lt;&gt;&apos;&nbsp;&#65;&#x27;&#x1F680;&#1114111; &bogus; &amp &#x0000041; &#x00000041; a && b < unclosed"#,
                "let x = \"a\" &<>'\u{00A0}A'🚀\u{10FFFF} &bogus; &amp A &#x00000041; a && b < unclosed"
            ),
            (
                "\r\n  <span class=\"hljs-keyword\">let</span> π = <span class=\"hljs-string\">\"🚀\"</span>\r\n  // cafe\u{0301} — &lt;\u{0301}\r\n  ",
                "let π = \"🚀\"\r\n  // cafe\u{0301} — <\u{0301}"
            ),
            (
                "\u{2063}\n    <span class=\"hljs-keyword\">indented</span>\r\n  \n\u{2063}",
                "\u{2063}\n    indented\r\n  \n\u{2063}"
            ),
            (
                #"<span class="hljs-title class_">C<span class="hljs-built_in">B</span></span><span class="hljs-built_in">D</span><span class="hljs-meta"><span class="hljs-string">ms</span></span><span class="hljs-string">s</span><span class="hljs-tie">t</span>"#,
                "CBDmsst"
            ),
            (
                #"<span class="hljs-link">url<span class="hljs-unmatched">/path</span></span><span class="hljs-under">u</span>"#,
                "url/pathu"
            ),
            (
                #"<span class="hljs-keyword">foo</span><span class="hljs-string"></span><span class='hljs-keyword'>bar</span><b>ignored</b></span>tail"#,
                "foobarignoredtail"
            ),
        ]

        for entry in cases {
            let tokenized = HighlightMarkup.tokenize(entry.markup, stylesheet: stylesheet)
            let attributed = HighlightMarkup.attributedString(entry.markup, css: css)
            XCTAssertEqual(tokenized.text, entry.expectedText)
            assertRunInvariants(text: tokenized.text, runs: tokenized.runs, attributed: attributed)
        }

        let underlineCase = HighlightMarkup.tokenize(
            #"<span class="hljs-link">url<span class="hljs-unmatched">/path</span></span><span class="hljs-under">u</span>"#,
            stylesheet: stylesheet
        )
        XCTAssertEqual(underlineCase.runs.count, 2)
        XCTAssertEqual(underlineCase.runs[0].text, "url/path")
        XCTAssertEqual(underlineCase.runs[0].utf16Range, 0..<8)
        XCTAssertEqual(underlineCase.runs[0].foregroundColor.map(rgbaHex), "#0000ffff")
        XCTAssertTrue(underlineCase.runs[0].isUnderlined)
        XCTAssertEqual(underlineCase.runs[1].text, "u")
        XCTAssertEqual(underlineCase.runs[1].utf16Range, 8..<9)
        XCTAssertEqual(underlineCase.runs[1].foregroundColor.map(rgbaHex), "#10203080")
        XCTAssertTrue(underlineCase.runs[1].isUnderlined)

        let surrogateCase = HighlightMarkup.tokenize(
            #"<span class="hljs-keyword">🚀</span><span class="hljs-string">a\r\nb</span>"#,
            stylesheet: stylesheet
        )
        // UTF-16: 🚀 is 2 units; "a\r\nb" literal here has escaped \r\n; test actual CRLF below.
        XCTAssertEqual(surrogateCase.runs[0].utf16Range, 0..<2)
        let crlfCase = HighlightMarkup.tokenize(
            "<span class=\"hljs-keyword\">🚀</span><span class=\"hljs-string\">a\r\nb</span>",
            stylesheet: stylesheet
        )
        XCTAssertEqual(crlfCase.runs[0].utf16Range, 0..<2)
        XCTAssertEqual(crlfCase.runs[1].utf16Range, 2..<6)
        XCTAssertEqual(crlfCase.text.utf16.count, 6)
    }

    func testRequestRunsSyncMatchesRequestSyncAndAsyncAcrossModesMetadataAndThemes() async throws {
        let highlighter = Highlight()
        let baseDark = HighlightColors.dark(.xcode)
        let diffColors = HighlightColors.custom(
            css: baseDark.css + ".hljs-addition{color:#00aa44}.hljs-deletion{color:#cc2233}.hljs-meta{color:#888888}",
            background: baseDark.background
        )
        let customShortHex = HighlightColors.custom(
            css: ".hljs{color:#222}.hljs-link{color:#00f;text-decoration:underline}",
            background: "fff"
        )
        let customAlphaHex = HighlightColors.custom(
            css: ".hljs{color:#222}.hljs-keyword{color:#aabbcc}",
            background: "#80112233"
        )
        let customEmptyBackground = HighlightColors.custom(
            css: ".hljs{color:#222}",
            background: ""
        )

        let matrix: [(String, HighlightMode, HighlightColors)] = [
            ("\u{2063}\n    let π = \"🚀 & <tag>\"\r\n    return π\n\u{2063}", .languageAliasIgnoreIllegal("swift"), baseDark),
            ("@@ -1 +1 @@\n-let old = 1\n+let new = 2", .languageAliasIgnoreIllegal("diff"), diffColors),
            ("let x = [1, 2, 3] // café", .language(.swift), .light(.xcode)),
            ("https://example.com [link](https://example.com)", .language(.markdown), .dark(.atomOne)),
            ("{\"a\": true, \"b\": \"🚀\"}", .languageIgnoreIllegal(.json), customShortHex),
            ("def greet(name):\n    return f\"hi {name}\"", .automatic, customAlphaHex),
            ("", .automatic, customEmptyBackground),
            ("   \r\n\t  ", .language(.swift), baseDark),
            ("  <&> untrimmed  ", .languageAlias("unknown-to-the-bundle"), baseDark),
            ("", .languageAlias("unknown-to-the-bundle"), baseDark),
        ]

        for (code, mode, colors) in matrix {
            let runsResult = try assertRequestParity(code, mode: mode, colors: colors, highlighter: highlighter)
            let asyncResult = try await highlighter.request(code, mode: mode, colors: colors)
            XCTAssertEqual(runsResult.isUndefined, asyncResult.isUndefined)
            XCTAssertEqual(runsResult.language, asyncResult.language)
            XCTAssertEqual(runsResult.languageName, asyncResult.languageName)
            XCTAssertEqual(runsResult.relevance, asyncResult.relevance)
            XCTAssertEqual(runsResult.hasIllegal, asyncResult.hasIllegal)
            XCTAssertEqual(runsResult.backgroundColor, asyncResult.backgroundColor)
            assertRunInvariants(text: runsResult.text, runs: runsResult.runs, attributed: asyncResult.attributedText)
        }

        let undefinedText = try assertRequestParity(
            "  <&> untrimmed  ",
            mode: .languageAlias("unknown-to-the-bundle"),
            colors: baseDark,
            highlighter: highlighter
        )
        XCTAssertTrue(undefinedText.isUndefined)
        XCTAssertEqual(undefinedText.language, "unknown")
        XCTAssertEqual(undefinedText.languageName, "Unknown")
        XCTAssertEqual(undefinedText.text, "  <&> untrimmed  ")
        XCTAssertEqual(
            undefinedText.runs,
            [HighlightRun(text: "  <&> untrimmed  ", utf16Range: 0..<17, foregroundColor: nil, isUnderlined: false)]
        )

        let undefinedEmpty = try assertRequestParity(
            "",
            mode: .languageAlias("unknown-to-the-bundle"),
            colors: baseDark,
            highlighter: highlighter
        )
        XCTAssertTrue(undefinedEmpty.isUndefined)
        XCTAssertEqual(undefinedEmpty.text, "")
        XCTAssertTrue(undefinedEmpty.runs.isEmpty)
    }

    func testEngineReusesImmutableStylesheetAcrossRequestsAndPreservesResults() throws {
        let engineA = Highlight()
        let engineB = Highlight()
        let ordinary = HighlightColors.dark(.xcode)
        let diff = HighlightColors.custom(
            css: ordinary.css + ".hljs-addition{color:#00aa44}.hljs-meta{color:#888888}",
            background: ordinary.background
        )

        let firstOrdinary = try engineA.requestRunsSync("let a = 1", mode: .language(.swift), colors: ordinary)
        let sheetOrdinary1 = engineA.stylesheet(for: ordinary.css)
        let firstDiff = try engineA.requestRunsSync("@@ -1 +1 @@\n+a", mode: .languageAlias("diff"), colors: diff)
        let sheetDiff1 = engineA.stylesheet(for: diff.css)
        let secondOrdinary = try engineA.requestRunsSync("let a = 1", mode: .language(.swift), colors: ordinary)
        let sheetOrdinary2 = engineA.stylesheet(for: ordinary.css)
        let secondDiff = try engineA.requestRunsSync("@@ -1 +1 @@\n+a", mode: .languageAlias("diff"), colors: diff)
        let sheetDiff2 = engineA.stylesheet(for: diff.css)

        XCTAssertTrue(sheetOrdinary1 === sheetOrdinary2)
        XCTAssertTrue(sheetDiff1 === sheetDiff2)
        XCTAssertFalse(sheetOrdinary1 === sheetDiff1)
        XCTAssertEqual(firstOrdinary, secondOrdinary)
        XCTAssertEqual(firstDiff, secondDiff)

        let otherEngineResult = try engineB.requestRunsSync("let a = 1", mode: .language(.swift), colors: ordinary)
        let otherEngineSheet = engineB.stylesheet(for: ordinary.css)
        XCTAssertFalse(sheetOrdinary1 === otherEngineSheet)
        XCTAssertEqual(firstOrdinary, otherEngineResult)
    }

    func testParallelEnginesRunRequestRunsSyncConcurrentlyWithParity() throws {
        let workerCount = 8
        let samples: [(code: String, mode: HighlightMode, colors: HighlightColors)] = [
            ("\u{2063}\nlet π = \"🚀\"\r\nreturn π\n\u{2063}", .language(.swift), .dark(.xcode)),
            ("def f(x):\n    return x & 1", .language(.python), .light(.xcode)),
            ("{\"ok\": true, \"emoji\": \"🧪\"}", .language(.json), .dark(.atomOne)),
            ("<a href=\"https://example.com\">hi &amp; bye</a>", .language(.html), .light(.atomOne)),
        ]
        let expected: [(runs: HighlightRunsResult, sync: HighlightResult)] = try samples.map { sample in
            let reference = Highlight()
            let runs = try reference.requestRunsSync(sample.code, mode: sample.mode, colors: sample.colors)
            let sync = try reference.requestSync(sample.code, mode: sample.mode, colors: sample.colors)
            return (runs, sync)
        }

        let inFlight = expectation(description: "All 8 engines inside requestRunsSync at once")
        inFlight.expectedFulfillmentCount = workerCount
        let done = expectation(description: "All parallel workers completed")
        done.expectedFulfillmentCount = workerCount
        let release = DispatchSemaphore(value: 0)
        let program = try HLJSProgram.bundled.get()

        let engines: [Highlight] = try (0..<workerCount).map { worker in
            let engine = try program.makeEngine()
            let initialLanguage: String
            switch samples[worker % samples.count].mode {
            case .language(let language): initialLanguage = language.alias
            default: initialLanguage = "swift"
            }
            let api = try engine.load(language: initialLanguage)
            var gated = false
            let beforeHighlight: @convention(block) () -> Void = {
                guard !gated else { return }
                gated = true
                inFlight.fulfill()
                release.wait()
            }
            api.context.setObject(beforeHighlight, forKeyedSubscript: "beforeHighlight" as NSString)
            api.context.evaluateScript("hljs.addPlugin({'before:highlight': beforeHighlight})")
            return Highlight(hljs: HLJS(engine: engine))
        }

        for (worker, engine) in engines.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async {
                defer { done.fulfill() }
                for round in 0..<samples.count {
                    let index = (worker + round) % samples.count
                    let sample = samples[index]
                    do {
                        let actual = try engine.requestRunsSync(sample.code, mode: sample.mode, colors: sample.colors)
                        XCTAssertEqual(actual, expected[index].runs)
                        self.assertRunInvariants(
                            text: actual.text,
                            runs: actual.runs,
                            attributed: expected[index].sync.attributedText
                        )
                    } catch {
                        XCTFail("Worker \(worker) failed: \(error)")
                    }
                }
            }
        }

        let overlap = XCTWaiter.wait(for: [inFlight], timeout: 60)
        for _ in 0..<workerCount { release.signal() }
        XCTAssertEqual(overlap, .completed)
        wait(for: [done], timeout: 60)
    }

    /// Independent copy of the `a0d910b` `Character`-delimited markup parser
    /// used as a reference oracle for inputs without combining/Prepend scalars
    /// adjacent to ASCII HTML delimiters.
    private static func referenceA0D910BAttributedString(
        _ markup: String,
        stylesheet: HighlightStylesheet
    ) -> AttributedString {
        func classes(in tag: Substring) -> [String] {
            guard let attribute = tag.range(of: "class=") else { return [] }
            let afterEquals = tag[attribute.upperBound...]
            guard let quote = afterEquals.first, quote == "\"" || quote == "'" else { return [] }
            let value = afterEquals.dropFirst()
            guard let end = value.firstIndex(of: quote) else { return [] }
            return value[..<end]
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                .map(String.init)
        }
        func entity(_ name: Substring) -> String? {
            switch name {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos": return "'"
            case "nbsp": return "\u{00A0}"
            default:
                guard name.hasPrefix("#") else { return nil }
                let number = name.dropFirst()
                let value: UInt32?
                if number.hasPrefix("x") || number.hasPrefix("X") {
                    value = UInt32(number.dropFirst(), radix: 16)
                } else {
                    value = UInt32(number)
                }
                guard let value, let scalar = Unicode.Scalar(value) else { return nil }
                return String(Character(scalar))
            }
        }
        let text = markup.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = NSMutableAttributedString()
        var elements: [HighlightStylesheet.Element] = [.init(tag: "code", classes: ["hljs"])]
        var styles: [HighlightStylesheet.Style] = [stylesheet.style(for: elements, inheriting: nil)]
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            let style = styles[styles.count - 1]
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let color = style.color { attributes[.foregroundColor] = color }
            if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            output.append(NSAttributedString(string: pending, attributes: attributes))
            pending = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = text[text.index(after: index)..<close]
                if tag.hasPrefix("/") {
                    if tag.dropFirst().trimmingCharacters(in: .whitespaces) == "span", elements.count > 1 {
                        flush()
                        elements.removeLast()
                        styles.removeLast()
                    }
                } else if tag.hasPrefix("span") {
                    flush()
                    let element = HighlightStylesheet.Element(tag: "span", classes: classes(in: tag))
                    elements.append(element)
                    styles.append(stylesheet.style(for: elements, inheriting: styles[styles.count - 1]))
                }
                index = text.index(after: close)
            } else if character == "&",
                      let semicolon = text[index...].firstIndex(of: ";"),
                      text.distance(from: index, to: semicolon) <= 10,
                      let decoded = entity(text[text.index(after: index)..<semicolon]) {
                pending.append(decoded)
                index = text.index(after: semicolon)
            } else {
                pending.append(character)
                index = text.index(after: index)
            }
        }
        flush()
#if canImport(AppKit)
        return (try? AttributedString(output, including: \.appKit)) ?? AttributedString(output.string)
#else
        return (try? AttributedString(output, including: \.uiKit)) ?? AttributedString(output.string)
#endif
    }

    /// The byte tokenizer matches the independent `a0d910b` reference oracle
    /// across entity lengths, whitespace trimming, Unicode text, CSS cascade,
    /// and real highlight.js outputs where delimiters are not adjacent to
    /// combining marks or Prepend scalars.
    func testTokenizerMatchesA0D910BReferenceAcrossStandardMarkupAndRealHighlightJS() throws {
        let css = HighlightColors.dark(.xcode).css
            + ".hljs-link{color:#00aaff;text-decoration:underline}"
        let colors = HighlightColors.custom(css: css, background: HighlightColors.dark(.xcode).background)
        let stylesheet = HighlightStylesheet(css: css)

        let rawMarkups: [String] = [
            "",
            "   \t\r\n  ",
            "\u{00A0} \t\u{2028}",
            "\u{200B}<span class=\"hljs-keyword\">z</span>\u{200B}",
            "&amp\u{0301};",
            "&\u{0301}amp;",
            "&#00000065;",
            "&#000000065;",
            "&#x0000041;",
            "&#x00000041;",
            "&#+65;",
            "&bogus; &amp a && b < unclosed",
            "<span class=\"hljs-keyword\">a</span></\u{0301}span>b",
            "<span class=\"hljs-keyword\">a</span></\u{200B}span\u{00A0}>b",
            "π<span class=\"hljs-keyword\">let</span>🚀&amp;π",
            "\u{2063}\n<span class=\"hljs-keyword\">let</span> x = &amp;1\r\n\u{2063}",
            #"<span class="hljs-link">url<span class="hljs-unmatched">/path</span></span>"#,
        ]
        for markup in rawMarkups {
            let expected = Self.referenceA0D910BAttributedString(markup, stylesheet: stylesheet)
            let tokenized = HighlightMarkup.tokenize(markup, stylesheet: stylesheet)
            let actualAttributed = HighlightMarkup.attributedString(markup, css: css)
            assertRunInvariants(text: tokenized.text, runs: tokenized.runs, attributed: expected)
            assertRunInvariants(text: tokenized.text, runs: tokenized.runs, attributed: actualAttributed)
        }

        let hljs = HLJS()
        let highlighter = Highlight()
        let realCases: [(String, HighlightMode)] = [
            ("//\u{0301}\nlet x = 1", .languageAliasIgnoreIllegal("swift")),
            ("\u{2063}\n    let π = \"🚀 & <tag>\"\r\n    return π\n\u{2063}", .languageAliasIgnoreIllegal("swift")),
            ("def f(x):\n    return x & 1", .languageAliasIgnoreIllegal("python")),
            ("{\"ok\": true, \"emoji\": \"🚀\"}", .languageAliasIgnoreIllegal("json")),
            ("<a href=\"https://example.com\">hi &amp; bye</a>", .languageAliasIgnoreIllegal("html")),
            ("@@ -1 +1 @@\n-old\n+new", .languageAliasIgnoreIllegal("diff")),
        ]
        for (code, mode) in realCases {
            let raw = try hljs.highlightSync(code, mode: mode)
            let expected = raw.value == "undefined"
                ? AttributedString(stringLiteral: code)
                : Self.referenceA0D910BAttributedString(raw.value, stylesheet: stylesheet)
            let runsResult = try highlighter.requestRunsSync(code, mode: mode, colors: colors)
            let syncResult = try highlighter.requestSync(code, mode: mode, colors: colors)
            assertRunInvariants(text: runsResult.text, runs: runsResult.runs, attributed: expected)
            assertRunInvariants(text: runsResult.text, runs: runsResult.runs, attributed: syncResult.attributedText)
            XCTAssertEqual(NSAttributedString(syncResult.attributedText), NSAttributedString(expected))
        }
    }

    /// HTML delimiters (`<`, `>`, `&`, `;`) are ASCII code points, so combining
    /// marks and Prepend scalars adjacent to them stay text rather than
    /// suppressing entity decoding or swallowing tag boundaries.
    func testASCIIDelimitersDecodeAndCloseAcrossAdjacentCombiningMarksAndPrependScalars() throws {
        let css = HighlightColors.dark(.xcode).css
            + ".hljs-link{color:#00aaff;text-decoration:underline}"
        let colors = HighlightColors.custom(css: css, background: HighlightColors.dark(.xcode).background)
        let stylesheet = HighlightStylesheet(css: css)
        let rootColor = try XCTUnwrap(stylesheet.rootStyle.color.map(rgbaHex))
        let keywordColor = try XCTUnwrap(
            stylesheet.style(
                for: [HighlightStylesheet.rootElement, .init(tag: "span", classes: ["hljs-keyword"])],
                inheriting: stylesheet.rootStyle
            ).color.map(rgbaHex)
        )
        let numberColor = try XCTUnwrap(
            stylesheet.style(
                for: [HighlightStylesheet.rootElement, .init(tag: "span", classes: ["hljs-number"])],
                inheriting: stylesheet.rootStyle
            ).color.map(rgbaHex)
        )

        // Entity followed by combining/joiner/variation scalars decodes and retains the mark.
        let entityCases: [(markup: String, expected: String)] = [
            ("&amp;\u{0301}", "&\u{0301}"),
            ("&lt;\u{0301}", "<\u{0301}"),
            ("&gt;\u{0301}", ">\u{0301}"),
            ("&quot;\u{0301}", "\"\u{0301}"),
            ("&#65;\u{0301}", "A\u{0301}"),
            ("&#x27;\u{0301}", "'\u{0301}"),
            ("&amp;\u{0301};", "&\u{0301};"),
            ("&amp;\u{200D}", "&\u{200D}"),
            ("&amp;\u{0903}", "&\u{0903}"),
            ("&amp;\u{FE0F}", "&\u{FE0F}"),
            ("\u{0600}&amp;", "\u{0600}&"),
        ]
        for entry in entityCases {
            let tokenized = HighlightMarkup.tokenize(entry.markup, stylesheet: stylesheet)
            let attributed = HighlightMarkup.attributedString(entry.markup, css: css)
            XCTAssertEqual(tokenized.text, entry.expected)
            XCTAssertEqual(tokenized.runs.count, 1)
            XCTAssertEqual(tokenized.runs[0].foregroundColor.map(rgbaHex), rootColor)
            assertRunInvariants(text: tokenized.text, runs: tokenized.runs, attributed: attributed)
        }

        // Tag delimiters close at ASCII `>` and open at ASCII `<` regardless of adjacent marks.
        let openTagMark = HighlightMarkup.tokenize(
            "<span class=\"hljs-keyword\">\u{0301}</span>",
            stylesheet: stylesheet
        )
        XCTAssertEqual(openTagMark.text, "\u{0301}")
        XCTAssertEqual(openTagMark.runs.count, 1)
        XCTAssertEqual(openTagMark.runs[0].foregroundColor.map(rgbaHex), keywordColor)

        let closeTagMark = HighlightMarkup.tokenize(
            "<span class=\"hljs-keyword\">x</span>\u{0301}",
            stylesheet: stylesheet
        )
        XCTAssertEqual(closeTagMark.text, "x\u{0301}")
        XCTAssertEqual(closeTagMark.runs.map(\.text), ["x", "\u{0301}"])
        XCTAssertEqual(closeTagMark.runs.map { $0.foregroundColor.map(rgbaHex) }, [keywordColor, rootColor])

        let closeTagThenSpan = HighlightMarkup.tokenize(
            "<span class=\"hljs-keyword\">x</span>\u{0301} <span class=\"hljs-number\">1</span>",
            stylesheet: stylesheet
        )
        XCTAssertEqual(closeTagThenSpan.text, "x\u{0301} 1")
        XCTAssertEqual(closeTagThenSpan.runs.map(\.text), ["x", "\u{0301} ", "1"])
        XCTAssertEqual(
            closeTagThenSpan.runs.map { $0.foregroundColor.map(rgbaHex) },
            [keywordColor, rootColor, numberColor]
        )

        let underlineThenZWJ = HighlightMarkup.tokenize(
            "<span class=\"hljs-link\">x</span>\u{200D}<span class=\"hljs-number\">2</span>",
            stylesheet: stylesheet
        )
        XCTAssertEqual(underlineThenZWJ.text, "x\u{200D}2")
        XCTAssertEqual(underlineThenZWJ.runs.map(\.text), ["x", "\u{200D}", "2"])
        XCTAssertEqual(underlineThenZWJ.runs.map(\.isUnderlined), [true, false, false])

        let prependBeforeSpan = HighlightMarkup.tokenize(
            "\u{0600}<span class=\"hljs-keyword\">x</span>\u{0301}",
            stylesheet: stylesheet
        )
        XCTAssertEqual(prependBeforeSpan.text, "\u{0600}x\u{0301}")
        XCTAssertEqual(prependBeforeSpan.runs.map(\.text), ["\u{0600}", "x", "\u{0301}"])
        XCTAssertEqual(
            prependBeforeSpan.runs.map { $0.foregroundColor.map(rgbaHex) },
            [rootColor, keywordColor, rootColor]
        )

        // Real highlight.js text/swift/html inputs round-trip verbatim without text loss.
        let highlighter = Highlight()
        let realCases: [(String, HighlightMode)] = [
            ("&\u{0301}", .languageAliasIgnoreIllegal("text")),
            ("<\u{0301}", .languageAliasIgnoreIllegal("text")),
            (">\u{0301}", .languageAliasIgnoreIllegal("text")),
            ("\"\u{0301}", .languageAliasIgnoreIllegal("text")),
            ("1\u{0301} + 2", .languageAliasIgnoreIllegal("swift")),
            ("\"hi\"\u{0301} + 1", .languageAliasIgnoreIllegal("swift")),
            ("let\u{0301} x = 1", .languageAliasIgnoreIllegal("swift")),
            ("\u{0600}let x = 1", .languageAliasIgnoreIllegal("swift")),
            ("\u{0600}&", .languageAliasIgnoreIllegal("text")),
            ("\u{0600}1", .languageAliasIgnoreIllegal("swift")),
            ("<b>\u{0301}</b>", .languageAliasIgnoreIllegal("html")),
            ("\u{2063}\n&\u{0301}\n<\u{0301}\n>\u{0301}\nlet\u{0301} x = 1\n\u{0600}1\n\u{2063}", .languageAliasIgnoreIllegal("swift")),
        ]
        for (code, mode) in realCases {
            let runsResult = try highlighter.requestRunsSync(code, mode: mode, colors: colors)
            let syncResult = try highlighter.requestSync(code, mode: mode, colors: colors)
            XCTAssertFalse(runsResult.isUndefined)
            XCTAssertEqual(runsResult.text, code)
            assertRunInvariants(text: runsResult.text, runs: runsResult.runs, attributed: syncResult.attributedText)
        }

        let swiftKeywordMark = try highlighter.requestRunsSync(
            "let\u{0301} x = 1",
            mode: .languageAliasIgnoreIllegal("swift"),
            colors: colors
        )
        XCTAssertEqual(swiftKeywordMark.runs.first?.text, "let")
        XCTAssertEqual(swiftKeywordMark.runs.first?.foregroundColor.map(rgbaHex), keywordColor)
        XCTAssertEqual(swiftKeywordMark.runs.dropFirst().first?.text, "\u{0301} x = ")
        XCTAssertEqual(swiftKeywordMark.runs.dropFirst().first?.foregroundColor.map(rgbaHex), rootColor)
    }
}
