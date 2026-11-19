import Foundation
import JavaScriptCore

/// The source strings can cross VM boundaries. The grammar objects and their regexes cannot.
final class HLJSProgram: Sendable {
    private static let source = Result {
        guard let url = Bundle.module.url(forResource: "highlight.min", withExtension: "js") else {
            throw HLJSError.fileNotFound
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
    static let bundled = source.map { text in HLJSProgram { text } }
    private static let full = source.map(Script.init)

    fileprivate final class Script: @unchecked Sendable {
        let source: JSStringRef

        init(_ text: String) { source = JSStringCreateWithCFString(text as CFString) }
        deinit { JSStringRelease(source) }

        func evaluate(in context: JSContext) throws {
            guard JSEvaluateScript(context.jsGlobalContextRef, source, nil, nil, 1, nil) != nil
            else {
                throw HLJSError.hljsNotFound
            }
        }
    }

    private let core: Script
    private let modules: [Script]
    let names: [String]
    let dependencies: [String: [Int]]
    // These are the aliases and subLanguage edges of the bundled grammars. The registry test
    // reads both from the complete highlight.js program and checks every name against this index.
    private static let aliases: [String: [String]] = [
        "applescript": ["osascript"], "bash": ["sh"], "c": ["h"],
        "cpp": ["cc", "c++", "h++", "hpp", "hh", "hxx", "cxx"], "csharp": ["cs", "c#"],
        "diff": ["patch"], "django": ["jinja"], "dockerfile": ["docker"],
        "fortran": ["f90", "f95"], "go": ["golang"], "graphql": ["gql"], "haskell": ["hs"],
        "ini": ["toml"], "java": ["jsp"], "javascript": ["js", "jsx", "mjs", "cjs"],
        "kotlin": ["kt", "kts"], "makefile": ["mk", "mak", "make"],
        "markdown": ["md", "mkdown", "mkd"], "mathematica": ["mma", "wl"], "nix": ["nixos"],
        "objectivec": ["mm", "objc", "obj-c", "obj-c++", "objective-c++"], "ocaml": ["ml"],
        "perl": ["pl", "pm"], "plaintext": ["text", "txt"], "python": ["py", "gyp", "ipython"],
        "python-repl": ["pycon"], "ruby": ["rb", "gemspec", "podspec", "thor", "irb"],
        "rust": ["rs"], "shell": ["console", "shellsession"],
        "typescript": ["ts", "tsx", "mts", "cts"],
        "vbnet": ["vb"],
        "xml": ["html", "xhtml", "rss", "atom", "xjb", "xsd", "xsl", "plist", "wsf", "svg"],
        "yaml": ["yml"],
    ]
    private static let embedded: [String: [String]] = [
        "dart": ["markdown"], "django": ["xml"], "dockerfile": ["bash"],
        "javascript": ["xml", "css", "graphql"], "markdown": ["xml"], "perl": ["mojolicious"],
        "php-template": ["xml", "php"], "python-repl": ["python"], "shell": ["bash"],
        "typescript": ["xml", "css", "graphql"], "xml": ["css", "xml", "javascript", "handlebars"],
        "yaml": ["ruby"],
    ]

    init(read: () throws -> String) rethrows {
        let text = try read()
        let source = text as NSString
        // Each emitted grammar starts with its own banner and registers exactly that name.
        // An unpartitioned resource remains a complete, executable highlight.js program.
        let pattern =
            #"/\*! `([^`\r\n]+)` grammar compiled for Highlight\.js [^*\r\n]+\*/|hljs\.registerLanguage\(\s*"([^"]+)"\s*,"#
        let markers = try! NSRegularExpression(pattern: pattern)
            .matches(in: text, range: NSRange(location: 0, length: source.length))
        var names: [String] = []
        var starts: [Int] = []
        for pair in stride(from: 0, to: markers.count - 1, by: 2) {
            let header = markers[pair]
            let registration = markers[pair + 1]
            let name = header.range(at: 1)
            let key = registration.range(at: 2)
            guard name.location != NSNotFound, key.location != NSNotFound,
                source.substring(with: name) == source.substring(with: key)
            else { break }
            names.append(source.substring(with: name))
            starts.append(header.range.location)
        }
        guard let start = starts.first, names.count * 2 == markers.count,
            Set(names).count == names.count
        else {
            core = Script(text)
            modules = []
            self.names = []
            dependencies = [:]
            return
        }
        core = Script(source.substring(to: start))
        starts.append(source.length)
        modules = names.indices.map { index in
            Script(
                source.substring(
                    with: NSRange(
                        location: starts[index], length: starts[index + 1] - starts[index])))
        }
        self.names = names
        let ids = Dictionary(
            uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
        var index: [String: [Int]] = [:]
        for name in names {
            var needed: Set<Int> = []
            func include(_ name: String) {
                guard let id = ids[name], needed.insert(id).inserted else { return }
                for child in Self.embedded[name, default: []] { include(child) }
            }
            include(name)
            let ordered = needed.sorted()
            index[name] = ordered
            for alias in Self.aliases[name, default: []] { index[alias] = ordered }
        }
        dependencies = index
    }

    static func makeEngine(language: String?, context: JSContext? = JSContext()) throws -> Engine {
        if language == nil {
            return try Engine(context: context, script: full.get(), program: nil)
        }
        return try bundled.get().makeEngine(context: context)
    }

    func makeEngine(context: JSContext? = JSContext()) throws -> Engine {
        try Engine(context: context, script: core, program: modules.isEmpty ? nil : self)
    }

    final class Engine {
        private var program: HLJSProgram?
        private let api: JSValue
        private var installed: Set<Int> = []

        fileprivate init(context: JSContext?, script: Script, program: HLJSProgram?) throws {
            guard let context else { throw HLJSError.contextIsNil }
            try script.evaluate(in: context)
            guard let api = context.objectForKeyedSubscript("hljs"), !api.isUndefined else {
                throw HLJSError.hljsNotFound
            }
            self.program = program
            self.api = api
        }

        func load(language: String?) throws -> JSValue {
            guard let program else { return api }
            let needed = language.flatMap { program.dependencies[$0.lowercased()] }
            for id in needed ?? Array(program.modules.indices) where !installed.contains(id) {
                try program.modules[id].evaluate(in: api.context)
                installed.insert(id)
            }
            if installed.count == program.modules.count {
                // Detection breaks equal scores in the bundle's registration order.
                api.invokeMethod("configure", withArguments: [["languages": program.names]])
                self.program = nil
            }
            return api
        }
    }
}

final actor HLJS {
    /// The engine state is guarded by `lock`, not by the actor: `highlightSync`
    /// runs highlight.js on the CALLING thread — a caller that owns its own
    /// serial queue keeps the evaluation off Swift Concurrency's cooperative
    /// pool — and the actor-isolated `highlight` takes the same lock, so the
    /// two entries can never touch the context at once. JavaScriptCore
    /// serialises access to a virtual machine on its own; the lock is what
    /// keeps the lazy load and the `hljs` handle consistent across threads.
    private nonisolated(unsafe) var engine: HLJSProgram.Engine?
    private nonisolated let lock = NSLock()

    init(engine: HLJSProgram.Engine? = nil) { self.engine = engine }

    private nonisolated func load(language: String?) throws -> JSValue {
        if let engine { return try engine.load(language: language) }
        let engine = try HLJSProgram.makeEngine(language: language)
        self.engine = engine
        return try engine.load(language: language)
    }
    
    func highlight(_ text: String, mode: HighlightMode) throws -> HLJSResult {
        try highlightSync(text, mode: mode)
    }

    /// Runs highlight.js on the calling thread. Safe from any thread: calls
    /// serialise on the lock, so one `HLJS` is one engine — use one per queue
    /// for parallelism.
    nonisolated func highlightSync(_ text: String, mode: HighlightMode) throws -> HLJSResult {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .automatic:
            return try highlightAuto(text)
        case .languageAlias(let alias):
            return try highlight(text, language: alias, ignoreIllegals: false)
        case .languageAliasIgnoreIllegal(let alias):
            return try highlight(text, language: alias, ignoreIllegals: true)
        case .language(let language):
            return try highlight(text, language: language.alias, ignoreIllegals: false)
        case .languageIgnoreIllegal(let language):
            return try highlight(text, language: language.alias, ignoreIllegals: true)
        }
    }
    
    private nonisolated func highlightAuto(_ text: String) throws -> HLJSResult {
        let hljs = try load(language: nil)
        let jsResult = hljs.invokeMethod(
            "highlightAuto",
            withArguments: [text]
        )
        return try highlightResult(jsResult)
    }
    
    private nonisolated func highlight(_ text: String,
                                       language: String,
                                       ignoreIllegals: Bool) throws -> HLJSResult {
        var languageOptions: [String : Any] = [
            "language": language,
        ]
        if ignoreIllegals {
            languageOptions["ignoreIllegals"] = ignoreIllegals
        }
        let hljs = try load(language: language)
        let jsResult = hljs.invokeMethod(
            "highlight",
            withArguments: [text, languageOptions]
        )
        return try highlightResult(jsResult)
    }
    
    private nonisolated func highlightResult(_ result: JSValue?) throws -> HLJSResult {
        guard let result else {
            throw HLJSError.valueNotFound
        }
        let illegal = result.objectForKeyedSubscript("illegal").toBool()
        let relevance = result.objectForKeyedSubscript("relevance").toInt32()
        guard
            let value = result.objectForKeyedSubscript("value").toString(),
            let language = result.objectForKeyedSubscript("language").toString()
        else {
            throw HLJSError.valueNotFound
        }
        return HLJSResult(value: value, illegal: illegal, language: language, relevance: relevance)
    }
}

