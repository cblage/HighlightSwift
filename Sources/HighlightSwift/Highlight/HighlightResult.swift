import SwiftUI

/// One contiguous, coalesced run of decoded text with its resolved stylesheet attributes.
public struct HighlightRun: Equatable, Sendable {
    /// The decoded text for this run.
    public let text: String

    /// The run's range in UTF-16 code units within `HighlightRunsResult.text`.
    public let utf16Range: Range<Int>

    /// The resolved foreground color from the stylesheet, or `nil` when none applies.
    public let foregroundColor: HighlightPlatformColor?

    /// Whether `text-decoration: underline` applies to this run.
    public let isUnderlined: Bool

    public init(
        text: String,
        utf16Range: Range<Int>,
        foregroundColor: HighlightPlatformColor?,
        isUnderlined: Bool
    ) {
        self.text = text
        self.utf16Range = utf16Range
        self.foregroundColor = foregroundColor
        self.isUnderlined = isUnderlined
    }
}

/// The resolved token runs and metadata of a call to `Highlight.requestRunsSync`.
public struct HighlightRunsResult: Equatable, Sendable {
    /// The decoded, end-trimmed plain text (or verbatim input text when `isUndefined` is true).
    public let text: String

    /// The contiguous, coalesced non-empty token runs covering `text` in UTF-16 order.
    public let runs: [HighlightRun]

    /// The syntax highlight failed.
    public let isUndefined: Bool

    /// Illegal matches were found.
    public let hasIllegal: Bool

    /// The language identifier (`"unknown"` when undefined).
    public let language: String

    /// The language relevance score.
    public let relevance: Int

    /// The language name with a question mark if relevance is low, e.g. `"Python?"`, `"Swift"`, or `"C++"`.
    public let languageName: String

    /// The highlight mode used for this request.
    public let mode: HighlightMode

    /// The highlight style background color.
    public let backgroundColor: Color

    /// The raw background color hex string from `HighlightColors.background`.
    public let backgroundColorHex: String

    init(
        text: String,
        runs: [HighlightRun],
        mode: HighlightMode,
        highlightJSResult: HLJSResult,
        backgroundColorHex: String
    ) {
        self.text = text
        self.runs = runs
        self.hasIllegal = highlightJSResult.illegal
        if highlightJSResult.language == "undefined" {
            self.language = "unknown"
        } else {
            self.language = highlightJSResult.language
        }
        self.relevance = Int(highlightJSResult.relevance)
        self.isUndefined = highlightJSResult.value == "undefined"
        self.languageName = HighlightResult.languageName(highlightJSResult)
        self.mode = mode
        self.backgroundColor = HighlightResult.backgroundColor(backgroundColorHex)
        self.backgroundColorHex = backgroundColorHex
    }
}

/// The result of a call to Highlight
public struct HighlightResult: Equatable, Sendable {
    /// The syntax highlighted attributed text
    public let attributedText: AttributedString
    
    /// The syntax highlight failed
    public let isUndefined: Bool
    
    /// Illegal matches were found
    public let hasIllegal: Bool
    
    /// The language identifier
    public let language: String
    
    /// The language relevance score
    public let relevance: Int
    
    /// The language name with a question mark if relevance is low. e.g. "Python?", "Swift" or "C++"
    public let languageName: String
    
    /// The highlight style background color
    public let backgroundColor: Color
    
    init(attributedText: AttributedString,
         highlightJSResult: HLJSResult,
         backgroundColorHex: String) {
        self.attributedText = attributedText
        self.hasIllegal = highlightJSResult.illegal
        if highlightJSResult.language == "undefined" {
            self.language = "unknown"
        } else {
            self.language = highlightJSResult.language
        }
        self.relevance = Int(highlightJSResult.relevance)
        self.isUndefined = highlightJSResult.value == "undefined"
        self.languageName = HighlightResult.languageName(highlightJSResult)
        self.backgroundColor = HighlightResult.backgroundColor(backgroundColorHex)
    }

    init(attributedText: AttributedString, runsResult: HighlightRunsResult) {
        self.attributedText = attributedText
        self.isUndefined = runsResult.isUndefined
        self.hasIllegal = runsResult.hasIllegal
        self.language = runsResult.language
        self.relevance = runsResult.relevance
        self.languageName = runsResult.languageName
        self.backgroundColor = runsResult.backgroundColor
    }
    
    static func languageName(_ result: HLJSResult) -> String {
        let name: String
        switch result.language {
        case "undefined":
            name = "Unknown"
            return name
        case "xml": name = "HTML"
        case "cpp": name = "C++"
        case "csharp": name = "C#"
        case "graphql": name = "GraphQL"
        case "pgsql": name = "PostgreSQL"
        case "javascript": name = "JavaScript"
        case "typescript": name = "TypeScript"
        case "objectivec": name = "Objective-C"
        case "vbnet": name = "Visual Basic .NET"
        case "php-template": name = "PHP Template"
        case "css", "sql", "json", "php", "scss", "toml", "yaml", "wasm":
            name = result.language.uppercased()
        default:
            name = capitalizedLanguageName(result.language)
        }
        return name + (result.relevance <= 5 ? "?" : "")
    }

    private static func capitalizedLanguageName(_ language: String) -> String {
        let utf8 = language.utf8
        guard let first = utf8.first, first >= 0x61 && first <= 0x7A else {
            return language.capitalized
        }
        for byte in utf8.dropFirst() where byte < 0x61 || byte > 0x7A {
            return language.capitalized
        }
        var bytes = Array(utf8)
        bytes[0] = first - 0x20
        return String(decoding: bytes, as: UTF8.self)
    }
    
    static func backgroundColor(_ hex: String) -> Color {
        if let components = fastHexBackgroundComponents(hex) {
            return Color(
                .sRGB,
                red: Double(components.r) / 255,
                green: Double(components.g) / 255,
                blue: Double(components.b) / 255,
                opacity: Double(components.a) / 255
            )
        }
        var int: UInt64 = 0
        let hexString = hex.trimmingCharacters(in: .alphanumerics.inverted)
        Scanner(string: hexString).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexString.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        func rgba(_ value: UInt64) -> Double {
            Double(value) / 255
        }
        return Color(.sRGB, red: rgba(r), green: rgba(g), blue: rgba(b), opacity: rgba(a))
    }

    private static func fastHexBackgroundComponents(
        _ hex: String
    ) -> (a: UInt64, r: UInt64, g: UInt64, b: UInt64)? {
        let utf8 = hex.utf8
        for byte in utf8 where byte >= 0x80 { return nil }
        @inline(__always)
        func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
        }
        var start = utf8.startIndex
        var end = utf8.endIndex
        while start < end && !isASCIIAlphanumeric(utf8[start]) {
            utf8.formIndex(after: &start)
        }
        while end > start {
            let previous = utf8.index(before: end)
            if !isASCIIAlphanumeric(utf8[previous]) {
                end = previous
            } else {
                break
            }
        }
        let count = utf8.distance(from: start, to: end)
        if count != 3 && count != 6 && count != 8 {
            return (1, 1, 1, 0)
        }
        var value: UInt64 = 0
        var cursor = start
        while cursor < end {
            let byte = utf8[cursor]
            let digit: UInt64
            if byte >= 0x30 && byte <= 0x39 {
                digit = UInt64(byte - 0x30)
            } else if byte >= 0x41 && byte <= 0x46 {
                digit = UInt64(byte - 0x41 + 10)
            } else if byte >= 0x61 && byte <= 0x66 {
                digit = UInt64(byte - 0x61 + 10)
            } else {
                return nil
            }
            value = (value << 4) | digit
            utf8.formIndex(after: &cursor)
        }
        switch count {
        case 3:
            return (255, (value >> 8) * 17, (value >> 4 & 0xF) * 17, (value & 0xF) * 17)
        case 6:
            return (255, value >> 16, value >> 8 & 0xFF, value & 0xFF)
        case 8:
            return (value >> 24, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        default:
            return (1, 1, 1, 0)
        }
    }
}
