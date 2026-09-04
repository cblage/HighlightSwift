import Foundation
import JavaScriptCore

final actor HLJS {
    /// The engine state is guarded by `lock`, not by the actor: `highlightSync`
    /// runs highlight.js on the CALLING thread — a caller that owns its own
    /// serial queue keeps the evaluation off Swift Concurrency's cooperative
    /// pool — and the actor-isolated `highlight` takes the same lock, so the
    /// two entries can never touch the context at once. JavaScriptCore
    /// serialises access to a virtual machine on its own; the lock is what
    /// keeps the lazy load and the `hljs` handle consistent across threads.
    private nonisolated(unsafe) var hljs: JSValue?
    private nonisolated let lock = NSLock()

    private nonisolated func load() throws -> JSValue {
        if let hljs {
            return hljs
        }
        guard let context = JSContext() else {
            throw HLJSError.contextIsNil
        }
        let highlightPath = Bundle.module.path(forResource: "highlight.min", ofType: "js")
        guard let highlightPath else {
            throw HLJSError.fileNotFound
        }
        let highlightScript = try String(contentsOfFile: highlightPath)
        context.evaluateScript(highlightScript)
        guard let hljs = context.objectForKeyedSubscript("hljs") else {
            throw HLJSError.hljsNotFound
        }
        self.hljs = hljs
        return hljs
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
        let hljs = try load()
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
        let hljs = try load()
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

