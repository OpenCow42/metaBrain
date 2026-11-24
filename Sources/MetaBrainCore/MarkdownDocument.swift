import Foundation

struct MarkdownAnchor: Sendable {
    let selector: DocumentPassageSelector
    let range: Range<Int>
    let slug: String?
}

struct MarkdownLink: Codable, Equatable, Sendable {
    let syntax: DocumentLinkSyntax
    let start: Int
    let end: Int
    let snippet: String
    let label: String?
    let destination: String
    let embed: Bool?
    var sourceBlock: String?
}

struct MarkdownDocument: Sendable {
    let anchors: [MarkdownAnchor]
    let links: [MarkdownLink]

    init(body: String, includeLinks: Bool = true) {
        var scanner = MarkdownScanner(body)
        scanner.maskBlocks()
        scanner.maskInlineLiterals()
        anchors = scanner.anchors()
        links = includeLinks ? scanner.links(in: anchors) : []
    }

    func section(containing range: Range<Int>) -> Range<Int>? {
        anchors.last { anchor in
            anchor.slug != nil && anchor.range.lowerBound <= range.lowerBound
                && anchor.range.upperBound >= range.upperBound
        }?.range
    }

    func anchor(for selector: DocumentPassageSelector) throws -> MarkdownAnchor? {
        let matches: [MarkdownAnchor]
        let name: String
        switch selector {
        case .heading(let heading):
            name = heading
            let exact = anchors.filter {
                if case .heading(let text) = $0.selector { text.caseInsensitiveCompare(heading) == .orderedSame }
                else { false }
            }
            matches = exact.isEmpty ? anchors.filter { $0.slug == heading.lowercased() } : exact
        case .block(let block):
            name = block
            let normalized = Self.blockName(block)
            matches = anchors.filter { $0.selector == .block(normalized) }
        case .range:
            return nil
        }
        guard matches.count <= 1 else { throw DocumentPassageError.ambiguousSelector(name) }
        return matches.first
    }

    static func blockName(_ name: String) -> String {
        name.hasPrefix("^") ? String(name.dropFirst()) : name
    }
}

private struct MarkdownScanner {
    private static let backtick: Character = "\u{60}"
    let characters: [Character]
    let lines: [Range<Int>]
    var activeLines: [Bool]
    var visible: [Bool]

    init(_ body: String) {
        let characters = Array(body)
        var lines: [Range<Int>] = []
        var start = 0
        for index in characters.indices where characters[index].isNewline {
            lines.append(start..<index)
            start = index + 1
        }
        if start < characters.count { lines.append(start..<characters.count) }
        self.characters = characters
        self.lines = lines
        activeLines = Array(repeating: true, count: lines.count)
        visible = Array(repeating: true, count: characters.count)
    }

    mutating func maskBlocks() {
        var frontMatterEnd: Int?
        if let first = lines.first, text(first) == "---" {
            frontMatterEnd = lines.indices.dropFirst().first { index in
                let line = text(lines[index])
                return line == "---" || line == "..."
            }
        }
        var fence: (character: Character, length: Int)?
        var literalBlockEnd = 0
        for (number, line) in lines.enumerated() {
            let contents = trimmed(line)
            if let frontMatterEnd, number <= frontMatterEnd {
                maskLine(number)
            } else if let open = fence {
                if contents.lowerBound < contents.upperBound, characters[contents.lowerBound] == open.character {
                    let end = run(of: open.character, since: contents.lowerBound, until: contents.upperBound)
                    if end - contents.lowerBound >= open.length, trimmed(end..<contents.upperBound).isEmpty {
                        fence = nil
                    }
                }
                maskLine(number)
            } else if line.lowerBound < literalBlockEnd {
                mask(line.lowerBound..<min(literalBlockEnd, line.upperBound))
            } else if contents.isEmpty {
                if line.upperBound < characters.count { visible[line.upperBound] = false }
            } else {
                let first = characters[contents.lowerBound]
                let indented = contents.lowerBound - line.lowerBound >= 4
                    || characters[line.lowerBound..<contents.lowerBound].contains("\t")
                if indented {
                    maskLine(number)
                } else if let end = literalEnd(start: contents.lowerBound), end > line.upperBound {
                    literalBlockEnd = end
                    mask(contents.lowerBound..<line.upperBound)
                } else if first == "~" || first == Self.backtick {
                    let end = run(of: first, since: contents.lowerBound, until: contents.upperBound)
                    if end - contents.lowerBound >= 3,
                       first == "~" || !characters[end..<contents.upperBound].contains(first) {
                        fence = (first, end - contents.lowerBound)
                        maskLine(number)
                    }
                }
            }
        }
    }

    mutating func maskInlineLiterals() {
        var nextRun: [Int: Range<Int>] = [:]
        var closingRuns: [Int: Range<Int>] = [:]
        var index = characters.count
        while index > 0 {
            index -= 1
            guard visible[index] else {
                if !nextRun.isEmpty { nextRun.removeAll(keepingCapacity: true) }
                continue
            }
            guard characters[index] == Self.backtick else { continue }
            let end = index + 1
            while index > 0, visible[index - 1], characters[index - 1] == Self.backtick { index -= 1 }
            let length = end - index
            closingRuns[index] = nextRun[length]
            nextRun[length] = index..<end
        }

        index = 0
        while index < characters.count {
            guard visible[index] else {
                index += 1
                continue
            }
            let character = characters[index]
            if character == "\\", index + 1 < characters.count,
               characters[index + 1].isPunctuation || characters[index + 1].isSymbol {
                visible[index + 1] = false
                index += 2
                continue
            }

            if character == Self.backtick {
                if let closer = closingRuns[index] {
                    mask(index..<closer.upperBound)
                    index = closer.upperBound
                } else {
                    index = run(of: Self.backtick, since: index, until: characters.count)
                }
            } else if character == "<" || character == "%",
                      let end = literalEnd(start: index) {
                mask(index..<end)
                index = end
            } else {
                index += 1
            }
        }
    }

    func anchors() -> [MarkdownAnchor] {
        var headings: [Heading] = []
        var blocks: [MarkdownAnchor] = []
        var paragraph: Range<Int>?
        var precedingParagraph: Range<Int>?
        for (number, line) in lines.enumerated() {
            guard activeLines[number] else {
                paragraph = nil
                precedingParagraph = nil
                continue
            }
            let contents = trimmed(line)
            if contents.isEmpty {
                if let paragraph { precedingParagraph = paragraph }
                paragraph = nil
                continue
            }
            if let heading = atxHeading(contents, start: line.lowerBound) {
                headings.append(heading)
                paragraph = nil
                precedingParagraph = nil
                continue
            }
            if beginsListItem(contents) {
                paragraph = nil
                precedingParagraph = nil
            }
            if let previous = paragraph, let level = setextLevel(contents) {
                headings.append(Heading(title: text(previous), start: previous.lowerBound, level: level))
                precedingParagraph = nil
                paragraph = nil
                continue
            }
            if let suffix = blockSuffix(contents) {
                let prefix = trimmed(contents.lowerBound..<suffix.start)
                let bodyRange: Range<Int>?
                if prefix.isEmpty {
                    bodyRange = paragraph ?? precedingParagraph
                } else {
                    bodyRange = (paragraph?.lowerBound ?? prefix.lowerBound)..<prefix.upperBound
                }
                if let bodyRange {
                    blocks.append(MarkdownAnchor(selector: .block(suffix.name), range: bodyRange, slug: nil))
                }
                paragraph = nil
                precedingParagraph = nil
                continue
            }
            if !contents.contains(where: { visible[$0] }) {
                paragraph = nil
                precedingParagraph = nil
                continue
            }
            paragraph = (paragraph?.lowerBound ?? contents.lowerBound)..<contents.upperBound
        }

        var headingAnchors: [MarkdownAnchor] = []
        var open: [Heading] = []
        var usedSlugs: Set<String> = []
        var slugSuffixes: [String: Int] = [:]
        for var heading in headings {
            let base = Self.slug(heading.title)
            var slug = base
            while !usedSlugs.insert(slug).inserted {
                slugSuffixes[base, default: 0] += 1
                slug = "\(base)-\(slugSuffixes[base]!)"
            }
            heading.slug = slug
            while let parent = open.last, parent.level >= heading.level {
                headingAnchors.append(parent.anchor(ending: heading.start, characters: characters))
                open.removeLast()
            }
            open.append(heading)
        }
        headingAnchors += open.map { $0.anchor(ending: characters.count, characters: characters) }
        return (headingAnchors + blocks).sorted { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound { return lhs.range.lowerBound < rhs.range.lowerBound }
            return lhs.range.upperBound > rhs.range.upperBound
        }
    }

    func links(in anchors: [MarkdownAnchor]) -> [MarkdownLink] {
        let blocks = anchors.filter { $0.slug == nil }
        var nextBlock = 0
        var output: [MarkdownLink] = []
        var definitions: [String: String] = [:]
        var definitionLines: Set<Int> = []
        for (number, line) in lines.enumerated() where activeLines[number] {
            if let definition = referenceDefinition(in: line) {
                definitionLines.insert(number)
                if definitions[definition.label] == nil { definitions[definition.label] = definition.destination }
            }
        }
        for (number, line) in lines.enumerated() where activeLines[number] && !definitionLines.contains(number) {
            let closingBrackets = bracketPairs(in: line)
            var index = line.lowerBound
            while index < line.upperBound {
                guard visible[index], characters[index] == "[" else {
                    index += 1
                    continue
                }
                let parsed: ParsedLink?
                if has("[[", at: index, before: line.upperBound) {
                    parsed = wikiLink(at: index, in: line)
                } else {
                    parsed = markdownLink(at: index, in: line, closingBrackets: closingBrackets, definitions: definitions)
                }
                guard let parsed else {
                    index += 1
                    continue
                }
                let isEmbed = index > line.lowerBound
                    && characters[index - 1] == "!" && visible[index - 1]
                let start = isEmbed ? index - 1 : index
                while nextBlock < blocks.count, blocks[nextBlock].range.upperBound <= start { nextBlock += 1 }
                let sourceBlock: String?
                if nextBlock < blocks.count, blocks[nextBlock].range.contains(start),
                   case .block(let name) = blocks[nextBlock].selector {
                    sourceBlock = name
                } else {
                    sourceBlock = nil
                }
                let snippetStart = max(line.lowerBound, start - 80)
                let snippetEnd = min(line.upperBound, max(parsed.end, start + 80), snippetStart + 240)
                output.append(MarkdownLink(
                    syntax: parsed.syntax,
                    start: start,
                    end: parsed.end,
                    snippet: text(trimmed(snippetStart..<snippetEnd)),
                    label: parsed.label,
                    destination: parsed.destination,
                    embed: isEmbed ? true : nil,
                    sourceBlock: sourceBlock
                ))
                index = parsed.end
            }
        }
        return output
    }

    private struct Heading {
        let title: String
        let start: Int
        let level: Int
        var slug = ""

        func anchor(ending end: Int, characters: [Character]) -> MarkdownAnchor {
            var end = end
            while end > start, characters[end - 1].isWhitespace { end -= 1 }
            return MarkdownAnchor(selector: .heading(title), range: start..<end, slug: slug)
        }
    }

    private struct ParsedLink {
        let syntax: DocumentLinkSyntax
        let label: String?
        let destination: String
        let end: Int
    }

    private func wikiLink(at start: Int, in line: Range<Int>) -> ParsedLink? {
        var alias: Int?
        var cursor = start + 2
        while cursor + 1 < line.upperBound {
            if visible[cursor], characters[cursor] == "|", alias == nil { alias = cursor }
            if visible[cursor], characters[cursor] == "[" { return nil }
            if has("]]", at: cursor, before: line.upperBound) {
                let destination = text(trimmed((start + 2)..<(alias ?? cursor)))
                guard !destination.isEmpty else { return nil }
                let label = alias.map { text(trimmed(($0 + 1)..<cursor)) }
                return ParsedLink(syntax: .wiki, label: label, destination: destination, end: cursor + 2)
            }
            cursor += 1
        }
        return nil
    }

    private func markdownLink(
        at start: Int,
        in line: Range<Int>,
        closingBrackets: [Int: Int],
        definitions: [String: String]
    ) -> ParsedLink? {
        guard let close = closingBrackets[start] else { return nil }
        let label = text((start + 1)..<close)
        let next = close + 1
        if has("(", at: next, before: line.upperBound),
           let destination = inlineDestination(from: next + 1, before: line.upperBound) {
            return ParsedLink(syntax: .markdown, label: label, destination: destination.value, end: destination.end)
        }
        if let referenceClose = closingBrackets[next] {
            let reference = text((next + 1)..<referenceClose)
            guard let destination = definitions[Self.referenceLabel(reference.isEmpty ? label : reference)] else { return nil }
            return ParsedLink(syntax: .markdown, label: label, destination: destination, end: referenceClose + 1)
        }
        guard let destination = definitions[Self.referenceLabel(label)] else { return nil }
        return ParsedLink(syntax: .markdown, label: label, destination: destination, end: next)
    }

    private func referenceDefinition(in line: Range<Int>) -> (label: String, destination: String)? {
        let contents = trimmed(line)
        let start = contents.lowerBound
        guard has("[", at: start, before: contents.upperBound),
              !has("[[", at: start, before: contents.upperBound),
              let close = closingBracket(from: start, before: contents.upperBound),
              has(":", at: close + 1, before: contents.upperBound),
              let destination = destination(from: close + 2, before: contents.upperBound),
              !destination.value.isEmpty else { return nil }
        return (Self.referenceLabel(text((start + 1)..<close)), destination.value)
    }

    private func inlineDestination(from start: Int, before end: Int) -> (value: String, end: Int)? {
        guard let parsed = destination(from: start, before: end) else { return nil }
        var cursor = whitespaceEnd(from: parsed.end, before: end)
        if cursor > parsed.end, cursor < end, let close = titleDelimiter(characters[cursor]) {
            cursor += 1
            while cursor < end, !has(String(close), at: cursor, before: end) { cursor += 1 }
            guard cursor < end else { return nil }
            cursor = whitespaceEnd(from: cursor + 1, before: end)
        }
        guard has(")", at: cursor, before: end) else { return nil }
        return (parsed.value, cursor + 1)
    }

    private func destination(from start: Int, before end: Int) -> (value: String, end: Int)? {
        let start = whitespaceEnd(from: start, before: end)
        if start < end, characters[start] == "<" {
            var cursor = start + 1
            while cursor < end {
                if has(">", at: cursor, before: end) { return (text((start + 1)..<cursor), cursor + 1) }
                if has("<", at: cursor, before: end) { return nil }
                cursor += 1
            }
            return nil
        }

        var cursor = start
        var depth = 0
        while cursor < end, !characters[cursor].isWhitespace {
            if visible[cursor] {
                if characters[cursor] == "(" { depth += 1 }
                if characters[cursor] == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
            }
            cursor += 1
        }
        guard depth == 0 else { return nil }
        return (text(start..<cursor), cursor)
    }

    private func closingBracket(from start: Int, before end: Int) -> Int? {
        var depth = 0
        for index in start..<end where visible[index] {
            switch characters[index] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    private func bracketPairs(in line: Range<Int>) -> [Int: Int] {
        var pairs: [Int: Int] = [:]
        var open: [Int] = []
        for index in line where visible[index] {
            if characters[index] == "[" {
                open.append(index)
            } else if characters[index] == "]", let start = open.popLast() {
                pairs[start] = index
            }
        }
        return pairs
    }

    private func atxHeading(_ contents: Range<Int>, start: Int) -> Heading? {
        guard has("#", at: contents.lowerBound, before: contents.upperBound) else { return nil }
        let textStart = run(of: "#", since: contents.lowerBound, until: contents.upperBound)
        let level = textStart - contents.lowerBound
        guard level <= 6, textStart < contents.upperBound, characters[textStart].isWhitespace else { return nil }
        var title = trimmed(textStart..<contents.upperBound)
        var end = title.upperBound
        while end > title.lowerBound, has("#", at: end - 1, before: title.upperBound) { end -= 1 }
        if end > title.lowerBound, characters[end - 1].isWhitespace { title = trimmed(title.lowerBound..<end) }
        guard !title.isEmpty else { return nil }
        return Heading(title: text(title), start: start, level: level)
    }

    private func setextLevel(_ contents: Range<Int>) -> Int? {
        let marker = characters[contents.lowerBound]
        guard marker == "=" || marker == "-",
              contents.allSatisfy({ visible[$0] && characters[$0] == marker }) else { return nil }
        return marker == "=" ? 1 : 2
    }

    private func beginsListItem(_ contents: Range<Int>) -> Bool {
        let first = contents.lowerBound
        guard visible[first], first + 1 < contents.upperBound else { return false }
        if "-+*".contains(characters[first]) { return characters[first + 1].isWhitespace }
        var cursor = first
        while cursor < contents.upperBound, cursor - first < 9,
              let byte = characters[cursor].asciiValue, (48...57).contains(byte) {
            cursor += 1
        }
        return cursor > first && cursor + 1 < contents.upperBound
            && ".)".contains(characters[cursor]) && characters[cursor + 1].isWhitespace
    }

    private func blockSuffix(_ contents: Range<Int>) -> (start: Int, name: String)? {
        let end = contents.upperBound
        var start = end
        while start > contents.lowerBound, Self.isBlockNameCharacter(characters[start - 1]) { start -= 1 }
        guard start < end, start > contents.lowerBound, has("^", at: start - 1, before: end),
              start - 1 == contents.lowerBound || characters[start - 2].isWhitespace else { return nil }
        return (start - 1, text(start..<end))
    }

    private static func isBlockNameCharacter(_ character: Character) -> Bool {
        if character == "-" || character == "_" { return true }
        guard let ascii = character.asciiValue else { return false }
        return (48...57).contains(ascii) || (65...90).contains(ascii) || (97...122).contains(ascii)
    }

    private static func referenceLabel(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func slug(_ title: String) -> String {
        String(title.lowercased().compactMap { character -> Character? in
            if character.isWhitespace { return "-" }
            if character.isLetter || character.isNumber || character == "-" || character == "_" { return character }
            return nil
        })
    }

    private func literalEnd(start: Int) -> Int? {
        let end = characters.count
        if matches("%%", at: start, before: end) {
            return literalClose("%%", from: start + 2)
        }
        if matches("<!--", at: start, before: end) {
            return literalClose("-->", from: start + 4) ?? end
        }
        for tag in ["code", "pre"] {
            guard matches("<\(tag)", at: start, before: end, ignoringCase: true) else { continue }
            let suffix = start + tag.count + 1
            guard suffix < end, characters[suffix].isWhitespace || characters[suffix] == ">" else { continue }
            return literalClose("</\(tag)>", from: suffix, ignoringCase: true) ?? end
        }
        return nil
    }

    private func literalClose(_ token: String, from start: Int, ignoringCase: Bool = false) -> Int? {
        let end = characters.count
        return (start..<end).first { matches(token, at: $0, before: end, ignoringCase: ignoringCase) }
            .map { $0 + token.count }
    }

    private func titleDelimiter(_ opening: Character) -> Character? {
        switch opening {
        case "\"", "'": opening
        case "(": ")"
        default: nil
        }
    }

    private func run(of character: Character, since start: Int, until end: Int) -> Int {
        var index = start
        while index < end, characters[index] == character { index += 1 }
        return index
    }

    private func whitespaceEnd(from start: Int, before end: Int) -> Int {
        var index = start
        while index < end, characters[index].isWhitespace { index += 1 }
        return index
    }

    private func trimmed(_ range: Range<Int>) -> Range<Int> {
        let start = whitespaceEnd(from: range.lowerBound, before: range.upperBound)
        var end = range.upperBound
        while end > start, characters[end - 1].isWhitespace { end -= 1 }
        return start..<end
    }

    private func text(_ range: Range<Int>) -> String { String(characters[range]) }

    private func has(_ token: String, at start: Int, before end: Int) -> Bool {
        matches(token, at: start, before: end) && (start..<(start + token.count)).allSatisfy { visible[$0] }
    }

    private func matches(_ token: String, at start: Int, before end: Int, ignoringCase: Bool = false) -> Bool {
        guard start <= end, token.count <= end - start else { return false }
        let content = characters[start..<(start + token.count)]
        return ignoringCase ? String(content).caseInsensitiveCompare(token) == .orderedSame : content.elementsEqual(token)
    }

    private mutating func mask(_ range: Range<Int>) {
        for index in range { visible[index] = false }
    }

    private mutating func maskLine(_ number: Int) {
        activeLines[number] = false
        let line = lines[number]
        mask(line.lowerBound..<min(line.upperBound + 1, characters.count))
    }
}
