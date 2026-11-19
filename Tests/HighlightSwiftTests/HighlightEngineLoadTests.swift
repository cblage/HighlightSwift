import Foundation
import JavaScriptCore
import XCTest

@testable import HighlightSwift

final class HighlightEngineLoadTests: XCTestCase {
    private let colors = HighlightColors.custom(
        css:
            ".hljs{color:#111111}.hljs-keyword{color:#222222}.hljs-string{text-decoration:underline}"
    )

    private struct Expected {
        let language: String
        let relevance: Int
        let markup: String
    }

    private struct Fixture {
        let code: String
        let language: HighlightLanguage
        let alias: String
        let tagged: Expected
        let detected: Expected
        let runs: [String]
    }

    private var corpus: [Fixture] {
        let swift =
            #"<span class="hljs-keyword">let</span> π <span class="hljs-operator">=</span> <span class="hljs-number">7</span>"#
        let julia =
            #"<span class="hljs-keyword">let</span> <span class="hljs-literal">π</span> = <span class="hljs-number">7</span>"#
        let python = Expected(
            language: "python", relevance: 3,
            markup:
                #"<span class="hljs-keyword">def</span> <span class="hljs-title function_">f</span>(<span class="hljs-params">x</span>): <span class="hljs-keyword">return</span> x"#
        )
        let json = Expected(
            language: "json", relevance: 2,
            markup:
                #"<span class="hljs-punctuation">{</span><span class="hljs-attr">&quot;ok&quot;</span><span class="hljs-punctuation">:</span><span class="hljs-literal"><span class="hljs-keyword">true</span></span><span class="hljs-punctuation">}</span>"#
        )
        let html =
            #"<span class="hljs-tag">&lt;<span class="hljs-name">script</span>&gt;</span><span class="language-javascript"><span class="hljs-keyword">let</span> x=<span class="hljs-number">1</span>;</span><span class="hljs-tag">&lt;/<span class="hljs-name">script</span>&gt;</span>"#
        return [
            Fixture(
                code: "let π = 7", language: .swift, alias: "swift",
                tagged: Expected(language: "swift", relevance: 1, markup: swift),
                detected: Expected(language: "julia", relevance: 2, markup: julia),
                runs: ["let|222222ff|0", " π = 7|111111ff|0"]),
            Fixture(
                code: "def f(x): return x", language: .python, alias: "py",
                tagged: python, detected: python,
                runs: [
                    "def|222222ff|0", " f(x): |111111ff|0", "return|222222ff|0", " x|111111ff|0",
                ]),
            Fixture(
                code: #"{"ok":true}"#, language: .json, alias: "json", tagged: json, detected: json,
                runs: [#"{"ok":|111111ff|0"#, "true|222222ff|0", "}|111111ff|0"]),
            Fixture(
                code: "<script>let x=1;</script>", language: .html, alias: "html",
                tagged: Expected(language: "html", relevance: 4, markup: html),
                detected: Expected(
                    language: "django", relevance: 4,
                    markup: #"<span class="language-xml">"# + html + "</span>"),
                runs: ["<script>|111111ff|0", "let|222222ff|0", " x=1;</script>|111111ff|0"]),
        ]
    }

    private func runs(_ text: AttributedString) -> [String] {
        let string = NSAttributedString(text)
        var result: [String] = []
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) {
            attributes, range, _ in
            let value = string.attributedSubstring(from: range).string
            let color = attributes[.foregroundColor] as? HighlightPlatformColor
            #if canImport(AppKit)
                let rgb = color?.usingColorSpace(.sRGB)
            #else
                let rgb = color
            #endif
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            rgb?.getRed(&r, green: &g, blue: &b, alpha: &a)
            let hex = String(
                format: "%02x%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()),
                Int((b * 255).rounded()), Int((a * 255).rounded()))
            let underline = attributes[.underlineStyle] as? Int ?? 0
            result.append("\(value)|\(hex)|\(underline)")
        }
        return result
    }

    func testAllModesMatchOriginalMarkupAndAttributedRuns() async throws {
        for fixture in corpus {
            let rawEngine = HLJS()
            let highlighter = Highlight()
            let alias = Expected(
                language: fixture.alias, relevance: fixture.tagged.relevance,
                markup: fixture.tagged.markup)
            for (mode, expected): (HighlightMode, Expected) in [
                (.languageAlias(fixture.alias), alias),
                (.language(fixture.language), fixture.tagged),
                (.languageIgnoreIllegal(fixture.language), fixture.tagged),
                (.languageAliasIgnoreIllegal(fixture.alias), alias), (.automatic, fixture.detected),
            ] {
                let raw = try rawEngine.highlightSync(fixture.code, mode: mode)
                let result = try highlighter.requestSync(fixture.code, mode: mode, colors: colors)
                XCTAssertEqual(raw.value, expected.markup)
                XCTAssertEqual(raw.language, expected.language)
                XCTAssertEqual(result.language, expected.language)
                XCTAssertEqual(result.relevance, expected.relevance)
                XCTAssertFalse(result.hasIllegal)
                XCTAssertFalse(result.isUndefined)
                XCTAssertEqual(runs(result.attributedText), fixture.runs)
                let async = try await highlighter.request(fixture.code, mode: mode, colors: colors)
                XCTAssertEqual(async, result)
            }
        }
    }

    func testUnknownEmptyAndInvalidJSONMatchOriginalResults() throws {
        let rawEngine = HLJS()
        let highlighter = Highlight()
        let json =
            #"<span class="hljs-punctuation">{</span>oops<span class="hljs-punctuation">}</span>"#
        for (code, mode, markup, language, expectedRuns):
            (String, HighlightMode, String, String, [String]) in [
                (
                    "<&>", .languageAlias("unknown-to-the-bundle"), "undefined", "unknown",
                    ["<&>|00000000|0"]
                ),
                ("", .automatic, "", "unknown", []),
                ("{oops}", .language(.json), json, "json", ["{oops}|111111ff|0"]),
                ("{oops}", .languageIgnoreIllegal(.json), json, "json", ["{oops}|111111ff|0"]),
            ]
        {
            let raw = try rawEngine.highlightSync(code, mode: mode)
            let result = try highlighter.requestSync(code, mode: mode, colors: colors)
            XCTAssertEqual(raw.value, markup)
            XCTAssertEqual(result.language, language)
            XCTAssertEqual(result.relevance, 0)
            XCTAssertFalse(result.hasIllegal)
            XCTAssertEqual(result.isUndefined, markup == "undefined")
            XCTAssertEqual(runs(result.attributedText), expectedRuns)
        }
    }

    private let samples = [
        "applescript": #"tell application "Finder" to get name of startup disk"#,
        "awk": #"BEGIN { print "hello" }"#, "bash": #"if test -f "$HOME/x"; then echo ok; fi"#,
        "basic": "10 PRINT \"hello\"\n20 END", "c": "int main(void) { return 0; }",
        "cpp": "template<class T> T id(T x) { return x; }",
        "csharp": "public sealed class Item { }",
        "css": "@media screen { .item { color: #aabbee; } }",
        "dart": "/// **hello**\nvoid main() {}",
        "diff": "@@ -1 +1 @@\n-old\n+new", "django": "<b>{{ value|escape }}</b>",
        "dockerfile": "FROM ubuntu\nRUN echo \"$HOME\"",
        "elm": "module Main exposing (main)\nmain = 42",
        "fortran": "program demo\nimplicit none\nend program demo",
        "go": "func main() { println(42) }",
        "graphql": "query Item { item(id: 42) { name } }",
        "haskell": "square :: Int -> Int\nsquare x = x*x",
        "ini": "[server]\nport = 9876", "java": "public final class Item { int count = 1; }",
        "javascript": "const node = html`<b>${value}</b>`;", "json": #"{"ok":true,"count":42}"#,
        "julia": "function square(x::Int)\n    x^2\nend", "kotlin": "data class Item(val id: Int)",
        "less": "@base: #abc; .item { color: @base; }", "lua": "local function id(x) return x end",
        "makefile": "all: input\n\techo $@", "markdown": "# Title\n\n<div>some **text**</div>",
        "mathematica": "Table[x^2, {x, 1, 3}]", "matlab": "function y = square(x)\ny = x.^2;\nend",
        "nix": "{ pkgs }: pkgs.hello", "objectivec": "@interface Item : NSObject\n@end",
        "ocaml": "let rec length = function [] -> 0 | x::xs -> 1 + length xs",
        "perl": #"my $n = shift; print "$n\n";"#, "php": "<?php echo $item; ?>",
        "php-template": "<p><?= $item ?></p>", "plaintext": "plain <text> & more",
        "python": "def square(x):\n    return x**2", "python-repl": ">>> print(42)\n42",
        "r": "mean(c(1, 2, 3), na.rm=TRUE)", "ruby": "def square(x)\n  x**2\nend",
        "rust": "fn main() { let x: usize = 42; }", "scala": "case class Item(id: Int)",
        "scss": "$base: #abc; .item { color: $base; }", "shell": "$ echo \"$HOME\"",
        "sql": "SELECT COUNT(*) FROM items WHERE id > 1;", "swift": "let π: Double = 3.14",
        "typescript": "const node: Node = html`<i>${value}</i>`;",
        "vbnet": "Public Class Item\nEnd Class",
        "wasm": "(module (func (export \"answer\") (result i32) i32.const 42))",
        "xml": "<style>b{color:red}</style><script>let x=1;</script>",
        "yaml": "name: <%= user.name %>",
    ]

    private let typedLanguages: [HighlightLanguage] = [
        .appleScript, .arduino, .awk, .bash, .basic, .c, .cPlusPlus, .cSharp, .clojure, .css,
        .dart, .delphi, .diff, .django, .dockerfile, .elixir, .elm, .erlang, .gherkin, .go,
        .gradle, .graphQL, .haskell, .html, .java, .javaScript, .json, .julia, .kotlin, .latex,
        .less, .lisp, .lua, .makefile, .markdown, .mathematica, .matlab, .nix, .objectiveC,
        .perl, .php, .phpTemplate, .plaintext, .postgreSQL, .protocolBuffers, .python, .pythonRepl,
        .r, .ruby, .rust, .scala, .scss, .shell, .sql, .swift, .toml, .typeScript, .visualBasic,
        .webAssembly, .yaml,
    ]

    private func assertParity(
        _ text: String, mode: HighlightMode, reference: HLJS, actual: HLJS, publicEngine: Highlight,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let expected = try reference.highlightSync(text, mode: mode)
        let result = try actual.highlightSync(text, mode: mode)
        let message = "\(mode) on \(text)"
        XCTAssertEqual(result.value, expected.value, message, file: file, line: line)
        XCTAssertEqual(result.language, expected.language, message, file: file, line: line)
        XCTAssertEqual(result.illegal, expected.illegal, message, file: file, line: line)
        XCTAssertEqual(result.relevance, expected.relevance, message, file: file, line: line)
        let attributed =
            expected.value == "undefined"
            ? AttributedString(text)
            : HighlightMarkup.attributedString(expected.value, css: colors.css)
        let expectedPublic = HighlightResult(
            attributedText: attributed, highlightJSResult: expected,
            backgroundColorHex: colors.background)
        XCTAssertEqual(
            try publicEngine.requestSync(text, mode: mode, colors: colors), expectedPublic,
            message, file: file, line: line)
    }

    func testEveryBundledGrammarAliasAndPublicModeMatchesTheWholeScript() throws {
        let original = try HLJSProgram.makeEngine(language: nil)
        let api = try original.load(language: nil)
        let reference = HLJS(engine: original)
        let names = try XCTUnwrap(
            api.invokeMethod("listLanguages", withArguments: [])?.toArray() as? [String])
        XCTAssertEqual(Set(names), Set(samples.keys))
        var canonical: [String: String] = [:]
        for name in names {
            let text = try XCTUnwrap(samples[name])
            let grammar = try XCTUnwrap(api.invokeMethod("getLanguage", withArguments: [name]))
            let aliases = grammar.objectForKeyedSubscript("aliases").toArray() as? [String] ?? []
            for key in aliases + [name] {
                canonical[key] = name
                let actual = HLJS()
                let publicEngine = Highlight()
                for mode: HighlightMode in [
                    .languageAlias(key), .languageAliasIgnoreIllegal(key.uppercased()),
                ] {
                    try assertParity(
                        text, mode: mode, reference: reference, actual: actual,
                        publicEngine: publicEngine)
                }
            }
            let partial = HLJS()
            let publicEngine = Highlight()
            try assertParity(
                text, mode: .languageAlias(name), reference: reference, actual: partial,
                publicEngine: publicEngine)
            try assertParity(
                text, mode: .automatic, reference: reference, actual: partial,
                publicEngine: publicEngine)
        }
        for language in typedLanguages {
            let text = canonical[language.alias].flatMap { samples[$0] } ?? "let value = 1 < 2"
            let actual = HLJS()
            let publicEngine = Highlight()
            for mode: HighlightMode in [.language(language), .languageIgnoreIllegal(language)] {
                try assertParity(
                    text, mode: mode, reference: reference, actual: actual,
                    publicEngine: publicEngine)
            }
        }
        let actual = HLJS()
        let publicEngine = Highlight()
        for key in ["unknown-to-the-bundle", "http", "text", "sh", "yml", "c++", "js"] {
            try assertParity(
                "<&>", mode: .languageAliasIgnoreIllegal(key), reference: reference, actual: actual,
                publicEngine: publicEngine)
        }
    }

    func testOneEngineAddsLanguagesWithoutChangingEarlierResults() throws {
        let engine = try HLJSProgram.bundled.get().makeEngine()
        let actual = HLJS(engine: engine)
        let reference = HLJS(engine: try HLJSProgram.makeEngine(language: nil))
        let publicEngine = Highlight()
        let firstContext = try engine.load(language: "swift").context
        var earlier: [(String, String)] = []
        for (key, installed): (String, Set<String>) in [
            ("swift", ["swift"]), ("python", ["swift", "python"]),
            ("html", ["swift", "python", "css", "graphql", "javascript", "xml"]),
        ] {
            let api = try engine.load(language: key)
            XCTAssertTrue(api.context === firstContext)
            let registered = try XCTUnwrap(
                api.invokeMethod("listLanguages", withArguments: [])?.toArray() as? [String])
            XCTAssertEqual(Set(registered), installed)
            earlier.append((key, try XCTUnwrap(samples[key == "html" ? "xml" : key])))
            for (name, code) in earlier {
                try assertParity(
                    code, mode: .languageAlias(name), reference: reference, actual: actual,
                    publicEngine: publicEngine)
            }
        }
    }

    func testChangedOrMissingGrammarBannersUseTheCompleteProgram() throws {
        let resource = try XCTUnwrap(
            Bundle.module.url(forResource: "highlight.min", withExtension: "js"))
        let text = try String(contentsOf: resource, encoding: .utf8)
        let original = try HLJSProgram.makeEngine(language: nil)
        for source in [
            text.replacingOccurrences(of: "grammar compiled for Highlight.js", with: "language"),
            text.replacingOccurrences(of: "`applescript` grammar", with: "`other` grammar"),
        ] {
            let program = HLJSProgram { source }
            XCTAssertTrue(program.names.isEmpty)
            let engine = try program.makeEngine()
            let actual = HLJS(engine: engine)
            let reference = HLJS(engine: original)
            for mode: HighlightMode in [.languageAlias("html"), .automatic] {
                let code = try XCTUnwrap(samples["xml"])
                let expected = try reference.highlightSync(code, mode: mode)
                let result = try actual.highlightSync(code, mode: mode)
                XCTAssertEqual(result.value, expected.value)
                XCTAssertEqual(result.language, expected.language)
                XCTAssertEqual(result.relevance, expected.relevance)
                XCTAssertEqual(result.illegal, expected.illegal)
            }
        }
    }

    func testIndexMatchesEveryAliasAndEmbeddedGrammarInTheOriginalLibrary() throws {
        let program = try HLJSProgram.bundled.get()
        let api = try HLJSProgram.makeEngine(language: nil).load(language: nil)
        let names = try XCTUnwrap(
            api.invokeMethod("listLanguages", withArguments: [])?.toArray() as? [String])
        XCTAssertEqual(program.names, names)
        let inventory = """
            (() => {
                const names = hljs.listLanguages();
                const ids = new Map(names.map((name, i) => [hljs.getLanguage(name), i]));
                const edges = names.map(name => {
                    const deps = new Set(), seen = new Set();
                    function visit(mode) {
                        if (!mode || typeof mode !== "object" || seen.has(mode)) return;
                        seen.add(mode);
                        if (mode.subLanguage != null) {
                            const sub = mode.subLanguage;
                            for (const key of typeof sub === "string" ? [sub] : sub.length ? sub : names) {
                                const id = ids.get(hljs.getLanguage(key));
                                if (id !== undefined) deps.add(id);
                            }
                        }
                        Object.values(mode).forEach(visit);
                    }
                    visit(hljs.getLanguage(name));
                    return deps;
                });
                const inventory = Object.create(null);
                names.forEach((name, id) => {
                    const needed = new Set([id]);
                    for (const i of needed) for (const child of edges[i]) needed.add(child);
                    const sorted = Array.from(needed).sort((a, b) => a - b);
                    const lang = hljs.getLanguage(name);
                    for (const key of [name, ...(lang.aliases || [])]) {
                        if (hljs.getLanguage(key) === lang) inventory[key.toLowerCase()] = sorted;
                    }
                });
                return inventory;
            })()
            """
        let expected = try XCTUnwrap(
            api.context.evaluateScript(inventory)?.toDictionary() as? [String: [Int]])
        XCTAssertEqual(program.dependencies, expected)
    }

    func testOneReadSuppliesIndependentEnginesAndEachGrammarRegistersOnce() throws {
        var reads = 0
        let program = try HLJSProgram {
            reads += 1
            let url = try XCTUnwrap(
                Bundle.module.url(forResource: "highlight.min", withExtension: "js"))
            return try String(contentsOf: url, encoding: .utf8)
        }
        let first = try program.makeEngine()
        let reference = try first.load(language: nil)
        let expectedNames = try XCTUnwrap(
            reference.invokeMethod("listLanguages", withArguments: [])?.toArray() as? [String])
        for _ in 0..<4 {
            let engine = try program.makeEngine()
            let api = try engine.load(language: "text")
            XCTAssertEqual(
                api.invokeMethod("listLanguages", withArguments: []).toArray() as? [String],
                ["plaintext"])
            api.context.evaluateScript(
                """
                var registrations = [];
                const register = hljs.registerLanguage;
                hljs.registerLanguage = (name, grammar) => { registrations.push(name); register(name, grammar); };
                """)
            for language in ["html", "js", "HTML", "text"] {
                _ = try engine.load(language: language)
            }
            let added = try XCTUnwrap(
                api.context.evaluateScript("registrations")?.toArray() as? [String])
            XCTAssertEqual(Set(added), ["xml", "javascript", "css", "graphql"])
            XCTAssertEqual(added.count, Set(added).count)
            _ = try engine.load(language: nil)
            let all = try XCTUnwrap(
                api.context.evaluateScript("registrations")?.toArray() as? [String])
            XCTAssertEqual(Set(all).union(["plaintext"]), Set(expectedNames))
            XCTAssertEqual(all.count, expectedNames.count - 1)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(try HLJSProgram.bundled.get() === HLJSProgram.bundled.get())
    }

    func testEightEnginesExecuteJavaScriptConcurrently() throws {
        let count = 8
        let entered = expectation(description: "Each VM is inside its highlight call")
        entered.expectedFulfillmentCount = count
        let finished = expectation(description: "Each highlight produced its original result")
        finished.expectedFulfillmentCount = count
        let release = DispatchSemaphore(value: 0)
        let program = try HLJSProgram.bundled.get()
        let expected = corpus[0].tagged
        var machines: Set<JSContextGroupRef> = []
        let highlighters = try (0..<count).map { _ in
            let engine = try program.makeEngine()
            let api = try engine.load(language: "swift")
            let machine = try XCTUnwrap(JSContextGetGroup(api.context.jsGlobalContextRef))
            XCTAssertTrue(machines.insert(machine).inserted)
            let inside: @convention(block) () -> Void = {
                entered.fulfill()
                release.wait()
            }
            api.context.setObject(inside, forKeyedSubscript: "inside" as NSString)
            api.context.evaluateScript("hljs.addPlugin({'before:highlight': inside})")
            return HLJS(engine: engine)
        }
        for highlighter in highlighters {
            DispatchQueue.global(qos: .userInitiated).async {
                defer { finished.fulfill() }
                do {
                    let output = try highlighter.highlightSync("let π = 7", mode: .language(.swift))
                    XCTAssertEqual(output.value, expected.markup)
                    XCTAssertEqual(output.language, expected.language)
                    XCTAssertEqual(output.relevance, Int32(expected.relevance))
                } catch {
                    XCTFail("Highlight failed: \(error)")
                }
            }
        }
        let overlap = XCTWaiter.wait(for: [entered], timeout: 300)
        for _ in 0..<count { release.signal() }
        XCTAssertEqual(overlap, .completed)
        wait(for: [finished], timeout: 300)
    }
}
