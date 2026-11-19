import Foundation
#if canImport(AppKit)
import AppKit
public typealias HighlightPlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
public typealias HighlightPlatformColor = UIColor
#endif

/// Resolved token runs and attributed strings built from highlight.js's markup
/// and the stylesheet's colour rules directly. highlight.js emits nested
/// `<span class="…">` elements around escaped text, and a theme is a flat
/// list of rules over those classes, so the two are walked here: every run
/// of text takes the colour of the innermost element a rule reaches, its
/// ancestors' otherwise, the `.hljs` root's last. AppKit's HTML importer is
/// never used.
enum HighlightMarkup {
    struct Tokenized {
        let text: String
        let runs: [HighlightRun]
    }

    /// Tokenizes highlight.js's `markup` under `stylesheet` into decoded plain
    /// text and coalesced non-empty runs in UTF-16 order without touching
    /// `NSAttributedString`, `AttributedString`, or `AttributeScopes`.
    static func tokenize(_ markup: String, stylesheet: HighlightStylesheet) -> Tokenized {
        let text = trimWhitespaceAndNewlines(markup)
        guard !text.isEmpty else {
            return Tokenized(text: "", runs: [])
        }
        let utf8 = text.utf8
        // The element chain from the root down, the root being the
        // `<code class="hljs">` a theme's `.hljs` rule colours.
        var elements: [HighlightStylesheet.Element] = [HighlightStylesheet.rootElement]
        var styles: [HighlightStylesheet.Style] = [stylesheet.rootStyle]

        var fullText = ""
        fullText.reserveCapacity(utf8.count)
        var runs: [HighlightRun] = []
        var activeStyle: HighlightStylesheet.Style?
        var runText = ""
        var utf16Offset = 0

        @inline(__always)
        func emitCurrentRun() {
            guard let style = activeStyle, !runText.isEmpty else { return }
            let count = runText.utf16.count
            fullText.append(runText)
            runs.append(
                HighlightRun(
                    text: runText,
                    utf16Range: utf16Offset..<(utf16Offset + count),
                    foregroundColor: style.color,
                    isUnderlined: style.underline
                )
            )
            utf16Offset += count
            runText = ""
        }

        @inline(__always)
        func appendSlice(_ slice: Substring, style: HighlightStylesheet.Style) {
            guard !slice.isEmpty else { return }
            if let current = activeStyle, current != style {
                emitCurrentRun()
            }
            activeStyle = style
            runText.append(contentsOf: slice)
        }

        @inline(__always)
        func appendDecoded(_ decoded: String, style: HighlightStylesheet.Style) {
            if let current = activeStyle, current != style {
                emitCurrentRun()
            }
            activeStyle = style
            runText.append(decoded)
        }

        var index = utf8.startIndex
        let end = utf8.endIndex
        var chunkStart = index
        var hasUnclosedAngle = false

        @inline(__always)
        func flushChunk(upTo position: String.UTF8View.Index) {
            guard chunkStart < position else { return }
            appendSlice(text[chunkStart..<position], style: styles[styles.count - 1])
            chunkStart = position
        }

        while index < end {
            let byte = utf8[index]
            if byte == 0x3C && !hasUnclosedAngle {
                var cursor = utf8.index(after: index)
                while cursor < end && utf8[cursor] != 0x3E {
                    utf8.formIndex(after: &cursor)
                }
                if cursor < end {
                    flushChunk(upTo: index)
                    let tagStart = utf8.index(after: index)
                    let tag = text[tagStart..<cursor]
                    if tagStart < cursor && utf8[tagStart] == 0x2F {
                        if isClosingSpanTag(tag), elements.count > 1 {
                            elements.removeLast()
                            styles.removeLast()
                        }
                    } else if tag.hasPrefix("span") {
                        let element = HighlightStylesheet.Element(
                            tag: "span",
                            classes: classes(in: tag)
                        )
                        elements.append(element)
                        styles.append(
                            stylesheet.style(for: elements, inheriting: styles[styles.count - 1])
                        )
                    }
                    // Any other tag is not highlight.js's and carries nothing.
                    index = utf8.index(after: cursor)
                    chunkStart = index
                    continue
                } else {
                    hasUnclosedAngle = true
                }
            } else if byte == 0x26 {
                var cursor = utf8.index(after: index)
                var distance = 1
                var semicolon: String.UTF8View.Index?
                while cursor < end && distance <= 10 {
                    let candidate = utf8[cursor]
                    if candidate == 0x3B {
                        semicolon = cursor
                        break
                    }
                    if candidate == 0x3C || candidate == 0x26 || candidate >= 0x80 {
                        break
                    }
                    utf8.formIndex(after: &cursor)
                    distance += 1
                }
                if let semicolon,
                   let decoded = entity(text[utf8.index(after: index)..<semicolon]) {
                    flushChunk(upTo: index)
                    appendDecoded(decoded, style: styles[styles.count - 1])
                    index = utf8.index(after: semicolon)
                    chunkStart = index
                    continue
                }
            }
            utf8.formIndex(after: &index)
        }
        flushChunk(upTo: end)
        emitCurrentRun()
        return Tokenized(text: fullText, runs: runs)
    }

    /// The attributed string for highlight.js's `value` under `css`: the
    /// markup's ends trimmed as whitespace, every entity decoded, colour
    /// and underline the stylesheet's, and no font — the font is the
    /// caller's.
    static func attributedString(_ markup: String, css: String) -> AttributedString {
        let tokenized = tokenize(markup, stylesheet: HighlightStylesheet(css: css))
        return attributedString(text: tokenized.text, runs: tokenized.runs)
    }

    /// Builds an `AttributedString` from already-resolved token runs.
    static func attributedString(text: String, runs: [HighlightRun]) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        let output = NSMutableAttributedString(string: text)
        output.beginEditing()
        for run in runs {
            guard run.foregroundColor != nil || run.isUnderlined else { continue }
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let color = run.foregroundColor {
                attributes[.foregroundColor] = color
            }
            if run.isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.setAttributes(
                attributes,
                range: NSRange(location: run.utf16Range.lowerBound, length: run.utf16Range.count)
            )
        }
        output.endEditing()
#if canImport(AppKit)
        return (try? AttributedString(output, including: \.appKit)) ?? AttributedString(output.string)
#else
        return (try? AttributedString(output, including: \.uiKit)) ?? AttributedString(output.string)
#endif
    }

    private static func trimWhitespaceAndNewlines(_ markup: String) -> Substring {
        let utf8 = markup.utf8
        var start = utf8.startIndex
        var end = utf8.endIndex
        while start < end && isASCIIWhitespace(utf8[start]) {
            utf8.formIndex(after: &start)
        }
        while end > start {
            let previous = utf8.index(before: end)
            if isASCIIWhitespace(utf8[previous]) {
                end = previous
            } else {
                break
            }
        }
        guard start < end else { return markup[start..<end] }
        if utf8[start] < 0x80 && utf8[utf8.index(before: end)] < 0x80 {
            return markup[start..<end]
        }
        let scalars = markup.unicodeScalars
        var scalarStart = start
        var scalarEnd = end
        while scalarStart < scalarEnd && isWhitespaceOrNewline(scalars[scalarStart]) {
            scalars.formIndex(after: &scalarStart)
        }
        while scalarEnd > scalarStart {
            let previous = scalars.index(before: scalarEnd)
            if isWhitespaceOrNewline(scalars[previous]) {
                scalarEnd = previous
            } else {
                break
            }
        }
        return markup[scalarStart..<scalarEnd]
    }

    @inline(__always)
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// Matches Foundation's `CharacterSet.whitespacesAndNewlines` across all
    /// Unicode scalars (Unicode `White_Space` plus `U+200B`) without bridging.
    @inline(__always)
    private static func isWhitespaceOrNewline(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.value == 0x200B
    }

    @inline(__always)
    private static func isClosingSpanTag(_ tag: Substring) -> Bool {
        if tag == "/span" { return true }
        let scalars = tag.unicodeScalars
        var start = scalars.index(after: scalars.startIndex)
        var end = scalars.endIndex
        while start < end && isWhitespace(scalars[start]) {
            scalars.formIndex(after: &start)
        }
        while end > start {
            let previous = scalars.index(before: end)
            if isWhitespace(scalars[previous]) {
                end = previous
            } else {
                break
            }
        }
        return tag[start..<end] == "span"
    }

    /// Matches Foundation's `CharacterSet.whitespaces` (`U+0009`, `U+0020`,
    /// `U+200B`, and Unicode category `Zs`).
    @inline(__always)
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x20
            || scalar.value == 0x09
            || scalar.value == 0x200B
            || scalar.properties.generalCategory == .spaceSeparator
    }

    /// The classes of an opening tag's `class` attribute, either quote.
    private static func classes(in tag: Substring) -> [String] {
        let utf8 = tag.utf8
        let end = utf8.endIndex
        var cursor = utf8.startIndex
        // Search for ASCII "class=" without bridging to Foundation.
        var afterEquals: String.UTF8View.Index?
        while cursor < end {
            if utf8[cursor] == 0x63 {
                let c1 = utf8.index(after: cursor)
                if c1 < end && utf8[c1] == 0x6C {
                    let c2 = utf8.index(after: c1)
                    if c2 < end && utf8[c2] == 0x61 {
                        let c3 = utf8.index(after: c2)
                        if c3 < end && utf8[c3] == 0x73 {
                            let c4 = utf8.index(after: c3)
                            if c4 < end && utf8[c4] == 0x73 {
                                let c5 = utf8.index(after: c4)
                                if c5 < end && utf8[c5] == 0x3D {
                                    afterEquals = utf8.index(after: c5)
                                    break
                                }
                            }
                        }
                    }
                }
            }
            utf8.formIndex(after: &cursor)
        }
        guard let quoteIndex = afterEquals, quoteIndex < end else { return [] }
        let quote = utf8[quoteIndex]
        guard quote == 0x22 || quote == 0x27 else { return [] }
        let valueStart = utf8.index(after: quoteIndex)
        var quoteEnd = valueStart
        var hasSeparator = false
        while quoteEnd < end {
            let byte = utf8[quoteEnd]
            if byte == quote { break }
            if byte == 0x20 || byte == 0x09 || byte == 0x0A { hasSeparator = true }
            utf8.formIndex(after: &quoteEnd)
        }
        guard quoteEnd < end else { return [] }
        if !hasSeparator {
            return valueStart < quoteEnd ? [String(tag[valueStart..<quoteEnd])] : []
        }
        var result: [String] = []
        var tokenStart = valueStart
        var position = valueStart
        while position < quoteEnd {
            let byte = utf8[position]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A {
                if tokenStart < position {
                    result.append(String(tag[tokenStart..<position]))
                }
                position = utf8.index(after: position)
                tokenStart = position
            } else {
                utf8.formIndex(after: &position)
            }
        }
        if tokenStart < quoteEnd {
            result.append(String(tag[tokenStart..<quoteEnd]))
        }
        return result
    }

    /// The character for an entity's name, without its `&` and `;`: the
    /// five highlight.js escapes, the two other named ones a custom source
    /// may carry, and any numeric reference.
    private static func entity(_ name: Substring) -> String? {
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
            return String(scalar)
        }
    }
}

/// An immutable stylesheet's colour and underline rules, in the shape the themes
/// ship: minified rules over `hljs-` classes, a few compound
/// (`.hljs-title.class_`) or descendant (`.hljs-meta .hljs-string`)
/// selectors among them, and whatever a custom stylesheet adds — comments,
/// whitespace, `@media` blocks, `!important`. A rule keeps what a run and an
/// attributed string carry: `color` and `text-decoration: underline`. Font
/// weight and style are the caller's font's, and layout properties never reach
/// the text.
final class HighlightStylesheet: Sendable {
    struct Element: Sendable {
        let tag: String
        let classes: [String]
    }

    struct Style: Equatable, Sendable {
        var color: HighlightPlatformColor?
        var underline: Bool
    }

    static let rootElement = Element(tag: "code", classes: ["hljs"])

    /// One compound selector: the classes and tag an element must carry.
    /// An id, a pseudo-class or -element, or an attribute makes the part
    /// unmatchable, since no element here has one.
    private struct Part: Sendable {
        var classes: [String] = []
        var tag: String?
        var unmatchable = false

        func matches(_ element: Element) -> Bool {
            if unmatchable { return false }
            if let tag, tag != element.tag { return false }
            return classes.allSatisfy { element.classes.contains($0) }
        }

        var estimatedBytes: Int {
            MemoryLayout<Self>.stride
                + (tag?.utf8.count ?? 0)
                + classes.reduce(0) { $0 + MemoryLayout<String>.stride + $1.utf8.count }
        }
    }

    private struct Rule: Sendable {
        /// Outermost first; the last part is the element's own.
        let parts: [Part]
        let specificity: Int
        let order: Int
        let color: HighlightPlatformColor?
        let underline: Bool

        /// Descendant matching: the last part on the element, every
        /// earlier part on some ancestor above the one before it.
        func matches(_ elements: [Element]) -> Bool {
            guard let own = parts.last, let element = elements.last, own.matches(element) else { return false }
            var ancestor = elements.count - 2
            for part in parts.dropLast().reversed() {
                while ancestor >= 0, !part.matches(elements[ancestor]) { ancestor -= 1 }
                if ancestor < 0 { return false }
                ancestor -= 1
            }
            return true
        }

        var estimatedBytes: Int {
            MemoryLayout<Self>.stride
                + (color == nil ? 0 : 64)
                + parts.reduce(0) { $0 + $1.estimatedBytes }
        }
    }

    private let rulesByClass: [String: [Rule]]
    private let tagOrUniversalRules: [Rule]
    let rootStyle: Style
    let estimatedBytes: Int

    init(css: String) {
        var text = css
        while let start = text.range(of: "/*") {
            guard let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) else {
                text.removeSubrange(start.lowerBound...)
                break
            }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        var rulesByClass: [String: [Rule]] = [:]
        var tagOrUniversalRules: [Rule] = []
        var nextOrder = 0
        var estimatedBytes = MemoryLayout<HighlightStylesheet>.stride
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{") {
            let selectors = text[index..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            if selectors.hasPrefix("@") {
                // An at-rule's block, `@media` and its kind, is skipped
                // whole: its conditions are the browser's to evaluate.
                var depth = 0
                var cursor = open
                while cursor < text.endIndex {
                    if text[cursor] == "{" { depth += 1 } else if text[cursor] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    cursor = text.index(after: cursor)
                }
                index = cursor < text.endIndex ? text.index(after: cursor) : text.endIndex
                continue
            }
            guard let close = text[open...].firstIndex(of: "}") else { break }
            var color: HighlightPlatformColor?
            var underline = false
            for declaration in text[text.index(after: open)..<close].split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = pair[1].replacingOccurrences(of: "!important", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch name {
                case "color":
                    if let parsed = Self.color(value) { color = parsed }
                case "text-decoration", "text-decoration-line":
                    if value.contains("underline") { underline = true }
                default:
                    break
                }
            }
            if color != nil || underline {
                for selector in selectors.split(separator: ",") {
                    guard let parts = Self.parts(of: selector) else { continue }
                    let specificity = parts.reduce(0) { total, part in
                        total + part.classes.count * 100 + (part.tag == nil ? 0 : 1)
                    }
                    let rule = Rule(
                        parts: parts,
                        specificity: specificity,
                        order: nextOrder,
                        color: color,
                        underline: underline
                    )
                    nextOrder += 1
                    if parts.contains(where: { $0.unmatchable }) { continue }
                    estimatedBytes += rule.estimatedBytes
                    if let key = parts.last?.classes.first {
                        if rulesByClass[key] == nil {
                            estimatedBytes += MemoryLayout<String>.stride + key.utf8.count
                        }
                        rulesByClass[key, default: []].append(rule)
                    } else {
                        tagOrUniversalRules.append(rule)
                    }
                }
            }
            index = text.index(after: close)
        }
        self.rulesByClass = rulesByClass
        self.tagOrUniversalRules = tagOrUniversalRules
        self.estimatedBytes = estimatedBytes
        self.rootStyle = Self.resolveStyle(
            for: [Self.rootElement],
            inheriting: nil,
            rulesByClass: rulesByClass,
            tagOrUniversalRules: tagOrUniversalRules
        )
    }

    /// The style of the innermost element of `elements`: for each property,
    /// the matching rule of highest specificity, the latest among equals,
    /// and the parent's where no rule sets it.
    func style(for elements: [Element], inheriting parent: Style?) -> Style {
        Self.resolveStyle(
            for: elements,
            inheriting: parent,
            rulesByClass: rulesByClass,
            tagOrUniversalRules: tagOrUniversalRules
        )
    }

    private static func resolveStyle(
        for elements: [Element],
        inheriting parent: Style?,
        rulesByClass: [String: [Rule]],
        tagOrUniversalRules: [Rule]
    ) -> Style {
        var style = Style(color: parent?.color, underline: parent?.underline ?? false)
        guard let element = elements.last else { return style }
        var colorRank = (-1, -1)
        var underlineRank = (-1, -1)

        @inline(__always)
        func apply(_ candidates: [Rule]) {
            for rule in candidates where rule.matches(elements) {
                let rank = (rule.specificity, rule.order)
                if let color = rule.color, rank > colorRank {
                    style.color = color
                    colorRank = rank
                }
                if rule.underline, rank > underlineRank {
                    style.underline = true
                    underlineRank = rank
                }
            }
        }

        if !tagOrUniversalRules.isEmpty {
            apply(tagOrUniversalRules)
        }
        for className in element.classes {
            if let candidates = rulesByClass[className] {
                apply(candidates)
            }
        }
        return style
    }

    /// A selector's compound parts, outermost first; nil for a selector
    /// that is not a selector at all.
    private static func parts(of selector: Substring) -> [Part]? {
        let tokens = selector.replacingOccurrences(of: ">", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard !tokens.isEmpty else { return nil }
        return tokens.map { token in
            var part = Part()
            var kind: Character = "t"
            var name = ""
            func close() {
                switch kind {
                case ".": if !name.isEmpty { part.classes.append(name) }
                case "t": if !name.isEmpty { part.tag = name }
                default: part.unmatchable = true
                }
                name = ""
            }
            for character in token {
                switch character {
                case ".", "#", ":", "[":
                    close()
                    kind = character
                case "*":
                    close()
                    kind = "t"
                default:
                    name.append(character)
                }
            }
            close()
            return part
        }
    }

    /// A CSS colour: hex in its four lengths, `rgb()` and `rgba()`, and
    /// the named colours a theme uses; nil for anything else, which leaves
    /// the rule without a colour.
    private static func color(_ value: String) -> HighlightPlatformColor? {
        if value.hasPrefix("#") {
            let digits = Array(value.dropFirst())
            guard digits.allSatisfy(\.isHexDigit) else { return nil }
            func channel(_ index: Int) -> CGFloat? {
                switch digits.count {
                case 3, 4:
                    guard let nibble = digits[index].hexDigitValue else { return nil }
                    return CGFloat(nibble * 17) / 255
                case 6, 8:
                    guard let high = digits[index * 2].hexDigitValue,
                          let low = digits[index * 2 + 1].hexDigitValue else { return nil }
                    return CGFloat(high * 16 + low) / 255
                default:
                    return nil
                }
            }
            guard let red = channel(0), let green = channel(1), let blue = channel(2) else { return nil }
            let alpha = (digits.count == 4 || digits.count == 8) ? channel(3) ?? 1 : 1
            return make(red, green, blue, alpha)
        }
        if value.hasPrefix("rgb") {
            guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") else { return nil }
            let components = value[value.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .compactMap { component -> CGFloat? in
                    let text = component.trimmingCharacters(in: .whitespaces)
                    if text.hasSuffix("%"), let percent = Double(text.dropLast()) { return CGFloat(percent / 100) }
                    guard let number = Double(text) else { return nil }
                    return CGFloat(number)
                }
            guard components.count >= 3 else { return nil }
            let alpha = components.count >= 4 ? components[3] : 1
            return make(components[0] / 255, components[1] / 255, components[2] / 255, alpha)
        }
        guard let hex = namedColors[value] else { return nil }
        return color(hex)
    }

    private static func make(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> HighlightPlatformColor {
#if canImport(AppKit)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
#else
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
#endif
    }

    private static let namedColors: [String: String] = [
        "black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000",
        "blue": "#0000ff", "yellow": "#ffff00", "orange": "#ffa500", "purple": "#800080",
        "gray": "#808080", "grey": "#808080", "silver": "#c0c0c0", "maroon": "#800000",
        "navy": "#000080", "olive": "#808000", "teal": "#008080", "gold": "#ffd700",
        "cyan": "#00ffff", "aqua": "#00ffff", "magenta": "#ff00ff", "fuchsia": "#ff00ff",
        "lime": "#00ff00", "brown": "#a52a2a", "pink": "#ffc0cb", "coral": "#ff7f50",
        "salmon": "#fa8072", "khaki": "#f0e68c", "crimson": "#dc143c", "indigo": "#4b0082",
        "violet": "#ee82ee", "tomato": "#ff6347", "darkgray": "#a9a9a9", "darkgrey": "#a9a9a9",
        "lightgray": "#d3d3d3", "lightgrey": "#d3d3d3", "dimgray": "#696969", "dimgrey": "#696969",
    ]
}
