import Foundation

/// Per-engine cache of parsed immutable stylesheets keyed by raw CSS string.
/// Each `Highlight` owns its own cache so parallel instances never contend.
private final class HighlightStylesheetCache: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (css: String, stylesheet: HighlightStylesheet)?
    private var entries: [String: HighlightStylesheet] = [:]
    private var estimatedBytes = 0
    private let byteLimit = 4 * 1024 * 1024

    func stylesheet(for css: String) -> HighlightStylesheet {
        lock.lock()
        if let last, last.css == css {
            lock.unlock()
            return last.stylesheet
        }
        if let cached = entries[css] {
            last = (css, cached)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = HighlightStylesheet(css: css)
        let entryBytes = css.utf8.count + parsed.estimatedBytes

        lock.lock()
        if let cached = entries[css] {
            last = (css, cached)
            lock.unlock()
            return cached
        }
        if entryBytes <= byteLimit {
            if estimatedBytes + entryBytes > byteLimit {
                entries.removeAll(keepingCapacity: true)
                estimatedBytes = 0
            }
            entries[css] = parsed
            estimatedBytes += entryBytes
            last = (css, parsed)
        }
        lock.unlock()
        return parsed
    }
}

public final class Highlight: Sendable {
    private let hljs: HLJS
    private let stylesheets = HighlightStylesheetCache()
    
    public init() {
        self.hljs = HLJS()
    }

    internal init(hljs: HLJS) {
        self.hljs = hljs
    }
    
    /// Syntax highlight some text with automatic language detection.
    /// - Parameters:
    ///   - text: The plain text code to highlight.
    ///   - colors: The highlight colors to use (default: .xcode/.light).
    /// - Throws: Either a HighlightError or an Error.
    /// - Returns: A syntax highlighted attributed string.
    public func attributedText(_ text: String,
                               colors: HighlightColors = .light(.xcode)) async throws -> AttributedString {
        try await request(text, mode: .automatic, colors: colors).attributedText
    }
    
    /// Syntax highlight some text with a specific language.
    /// - Parameters:
    ///   - text: The plain text code to highlight.
    ///   - language: The supported language to use.
    ///   - colors: The highlight colors to use (default: .xcode/.light).
    /// - Throws: Either a HighlightError or an Error.
    /// - Returns: A syntax highlighted attributed string.
    public func attributedText(_ text: String,
                               language: HighlightLanguage,
                               colors: HighlightColors = .light(.xcode)) async throws -> AttributedString {
        try await request(text, mode: .language(language), colors: colors).attributedText
    }
    
    /// Syntax highlight some text with a specific language.
    /// - Parameters:
    ///   - text: The plain text code to highlight.
    ///   - language: The language alias to use.
    ///   - colors: The highlight colors to use (default: .xcode/.light).
    /// - Throws: Either a HighlightError or an Error.
    /// - Returns: A syntax highlighted attributed string.
    public func attributedText(_ text: String,
                               language: String,
                               colors: HighlightColors = .light(.xcode)) async throws -> AttributedString {
        try await request(text, mode: .languageAlias(language), colors: colors).attributedText
    }
    
    /// Syntax highlight some text and return detailed results.
    /// - Parameters:
    ///   - text: The plain text code to highlight.
    ///   - mode: The highlight mode to use (default: .automatic).
    ///   - colors: The highlight colors to use (default: .xcode/.light).
    /// - Throws: Either a HighlightError or an Error.
    /// - Returns: The result of the syntax highlight.
    public func request(_ text: String,
                        mode: HighlightMode = .automatic,
                        colors: HighlightColors = .light(.xcode)) async throws -> HighlightResult {
        let hljsResult = try await hljs.highlight(text, mode: mode)
        return result(text, mode: mode, hljsResult: hljsResult, colors: colors)
    }

    /// Syntax highlight some text and return detailed results, synchronously
    /// on the calling thread. `request` hops to an actor, which executes on
    /// Swift Concurrency's cooperative pool, so highlight.js evaluation there
    /// competes with everything else the pool runs; a caller that owns its own
    /// queue calls this instead. Calls on one `Highlight` serialise — use one
    /// instance per queue for parallelism. Not for the main thread.
    /// - Parameters:
    ///   - text: The plain text code to highlight.
    ///   - mode: The highlight mode to use (default: .automatic).
    ///   - colors: The highlight colors to use (default: .xcode/.light).
    /// - Throws: Either a HighlightError or an Error.
    /// - Returns: The result of the syntax highlight.
    public func requestSync(_ text: String,
                            mode: HighlightMode = .automatic,
                            colors: HighlightColors = .light(.xcode)) throws -> HighlightResult {
        let hljsResult = try hljs.highlightSync(text, mode: mode)
        return result(text, mode: mode, hljsResult: hljsResult, colors: colors)
    }

    /// Syntax highlight some text and return the resolved token runs and
    /// metadata synchronously on the calling thread, before any
    /// `NSAttributedString`, `AttributedString`, or `AttributeScopes` bridge.
    /// Calls on one `Highlight` serialise — use one instance per queue for
    /// parallelism. Not for the main thread.
    /// - Parameters:
    ///   - text: The plain text code to highlight.
    ///   - mode: The highlight mode to use (default: .automatic).
    ///   - colors: The highlight colors to use (default: .xcode/.light).
    /// - Throws: Either a HighlightError or an Error.
    /// - Returns: The resolved token runs and highlight metadata.
    public func requestRunsSync(_ text: String,
                                mode: HighlightMode = .automatic,
                                colors: HighlightColors = .light(.xcode)) throws -> HighlightRunsResult {
        let hljsResult = try hljs.highlightSync(text, mode: mode)
        return runsResult(text, mode: mode, hljsResult: hljsResult, colors: colors)
    }

    internal func stylesheet(for css: String) -> HighlightStylesheet {
        stylesheets.stylesheet(for: css)
    }

    private func runsResult(_ text: String,
                            mode: HighlightMode,
                            hljsResult: HLJSResult,
                            colors: HighlightColors) -> HighlightRunsResult {
        let isUndefined = hljsResult.value == "undefined"
        let resolvedText: String
        let runs: [HighlightRun]
        if isUndefined {
            resolvedText = text
            runs = text.isEmpty
                ? []
                : [
                    HighlightRun(
                        text: text,
                        utf16Range: 0..<text.utf16.count,
                        foregroundColor: nil,
                        isUnderlined: false
                    )
                ]
        } else {
            let stylesheet = stylesheets.stylesheet(for: colors.css)
            let tokenized = HighlightMarkup.tokenize(hljsResult.value, stylesheet: stylesheet)
            resolvedText = tokenized.text
            runs = tokenized.runs
        }
        return HighlightRunsResult(
            text: resolvedText,
            runs: runs,
            mode: mode,
            highlightJSResult: hljsResult,
            backgroundColorHex: colors.background
        )
    }

    private func result(_ text: String,
                        mode: HighlightMode,
                        hljsResult: HLJSResult,
                        colors: HighlightColors) -> HighlightResult {
        let resolved = runsResult(text, mode: mode, hljsResult: hljsResult, colors: colors)
        let attributedText: AttributedString
        if resolved.isUndefined {
            attributedText = AttributedString(stringLiteral: text)
        } else {
            attributedText = HighlightMarkup.attributedString(text: resolved.text, runs: resolved.runs)
        }
        return HighlightResult(attributedText: attributedText, runsResult: resolved)
    }
}
