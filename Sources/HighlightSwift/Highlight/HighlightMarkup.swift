import Foundation
#if canImport(AppKit)
import AppKit
typealias HighlightPlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
typealias HighlightPlatformColor = UIColor
#endif

/// The attributed string, built from highlight.js's markup and the
/// stylesheet's colour rules directly. highlight.js emits nested
/// `<span class="…">` elements around escaped text, and a theme is a flat
/// list of rules over those classes, so the two are walked here: every run
/// of text takes the colour of the innermost element a rule reaches, its
/// ancestors' otherwise, the `.hljs` root's last. AppKit's HTML importer,
/// which this replaces, is a WebKit document load whose parse runs on the
/// main thread whatever thread calls it, so a caller on its own queue
/// parked in the kernel for the parse's whole length while the main
/// thread paid a quarter second per highlighted block.
enum HighlightMarkup {
    /// The attributed string for highlight.js's `value` under `css`: the
    /// markup's ends trimmed as whitespace, every entity decoded, colour
    /// and underline the stylesheet's, and no font — the font is the
    /// caller's.
    static func attributedString(_ markup: String, css: String) -> AttributedString {
        let stylesheet = HighlightStylesheet(css: css)
        let text = markup.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = NSMutableAttributedString()
        // The element chain from the root down, the root being the
        // `<code class="hljs">` a theme's `.hljs` rule colours.
        var elements: [HighlightStylesheet.Element] = [.init(tag: "code", classes: ["hljs"])]
        var styles: [HighlightStylesheet.Style] = [stylesheet.style(for: elements, inheriting: nil)]
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            output.append(NSAttributedString(string: pending, attributes: styles[styles.count - 1].attributes))
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
                // Any other tag is not highlight.js's and carries nothing.
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

    /// The classes of an opening tag's `class` attribute, either quote.
    private static func classes(in tag: Substring) -> [String] {
        guard let attribute = tag.range(of: "class=") else { return [] }
        let afterEquals = tag[attribute.upperBound...]
        guard let quote = afterEquals.first, quote == "\"" || quote == "'" else { return [] }
        let value = afterEquals.dropFirst()
        guard let end = value.firstIndex(of: quote) else { return [] }
        return value[..<end].split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
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
            return String(Character(scalar))
        }
    }
}

/// A stylesheet's colour and underline rules, in the shape the themes
/// ship: minified rules over `hljs-` classes, a few compound
/// (`.hljs-title.class_`) or descendant (`.hljs-meta .hljs-string`)
/// selectors among them, and whatever a custom stylesheet adds — comments,
/// whitespace, `@media` blocks, `!important`. A rule keeps what an
/// attributed string can carry and this package hands on: `color` and
/// `text-decoration: underline`. Font weight and style are the caller's
/// font's, as they were when the importer's fonts were stripped, and the
/// layout properties never reached the text.
struct HighlightStylesheet {
    struct Element {
        let tag: String
        let classes: [String]
    }

    struct Style {
        var color: HighlightPlatformColor?
        var underline: Bool

        var attributes: [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let color { attributes[.foregroundColor] = color }
            if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            return attributes
        }
    }

    /// One compound selector: the classes and tag an element must carry.
    /// An id, a pseudo-class or -element, or an attribute makes the part
    /// unmatchable, since no element here has one.
    private struct Part {
        var classes: [String] = []
        var tag: String?
        var unmatchable = false

        func matches(_ element: Element) -> Bool {
            if unmatchable { return false }
            if let tag, tag != element.tag { return false }
            return classes.allSatisfy { element.classes.contains($0) }
        }
    }

    private struct Rule {
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
    }

    private let rules: [Rule]

    init(css: String) {
        var text = css
        while let start = text.range(of: "/*") {
            guard let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) else {
                text.removeSubrange(start.lowerBound...)
                break
            }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        var rules: [Rule] = []
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
                    rules.append(Rule(parts: parts, specificity: specificity, order: rules.count, color: color, underline: underline))
                }
            }
            index = text.index(after: close)
        }
        self.rules = rules
    }

    /// The style of the innermost element of `elements`: for each property,
    /// the matching rule of highest specificity, the latest among equals,
    /// and the parent's where no rule sets it.
    func style(for elements: [Element], inheriting parent: Style?) -> Style {
        var style = Style(color: parent?.color, underline: parent?.underline ?? false)
        var colorRank = -1
        var underlineRank = -1
        for rule in rules where rule.matches(elements) {
            let rank = rule.specificity * 10_000 + rule.order
            if let color = rule.color, rank > colorRank {
                style.color = color
                colorRank = rank
            }
            if rule.underline, rank > underlineRank {
                style.underline = true
                underlineRank = rank
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
