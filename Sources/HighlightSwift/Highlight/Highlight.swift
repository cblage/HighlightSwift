import Foundation

public final class Highlight: Sendable {
    private let hljs = HLJS()
    
    public init() {
        
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
        return try result(text, hljsResult: hljsResult, colors: colors)
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
        return try result(text, hljsResult: hljsResult, colors: colors)
    }

    private func result(_ text: String,
                        hljsResult: HLJSResult,
                        colors: HighlightColors) throws -> HighlightResult {
        let isUndefined = hljsResult.value == "undefined"
        let attributedText: AttributedString
        if isUndefined {
            attributedText = AttributedString(stringLiteral: text)
        } else {
            // Built from the markup and the stylesheet directly, on this
            // thread — see `HighlightMarkup`. The HTML importer this
            // replaces parsed on the main thread whatever thread called it.
            attributedText = HighlightMarkup.attributedString(hljsResult.value, css: colors.css)
        }
        return HighlightResult(
            attributedText: attributedText,
            highlightJSResult: hljsResult,
            backgroundColorHex: colors.background
        )
    }
}
