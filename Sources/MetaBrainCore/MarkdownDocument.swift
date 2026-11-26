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
        let references = scanner.references()
        anchors = scanner.anchors(excluding: references.lines)
        links = includeLinks ? scanner.links(in: anchors, references: references) : []
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
    var closedFences: [Int: Range<Int>] = [:]

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
        var fence: (character: Character, length: Int, quoteDepth: Int, contentStart: Int)?
        var literalBlockEnd = 0
        var paragraphOpen = false
        var previousQuoteDepth = 0
        let possibleFences = lines.compactMap { line -> Int? in
            let contents = quoteContents(trimmed(line)).contents
            return fenceMarker(contents) == nil ? nil : contents.lowerBound
        }
        var nextFence = 0
        for (number, line) in lines.enumerated() {
            while nextFence < possibleFences.count, possibleFences[nextFence] < line.upperBound { nextFence += 1 }
            let contents = trimmed(line)
            let quote = quoteContents(contents)
            if let open = fence, quote.depth < open.quoteDepth { fence = nil }
            if let frontMatterEnd, number <= frontMatterEnd {
                maskLine(number)
            } else if let open = fence {
                if quote.depth == open.quoteDepth, !quote.contents.isEmpty,
                   characters[quote.contents.lowerBound] == open.character {
                    let end = run(of: open.character, since: quote.contents.lowerBound, until: quote.contents.upperBound)
                    if end - quote.contents.lowerBound >= open.length, trimmed(end..<quote.contents.upperBound).isEmpty {
                        if open.quoteDepth == 0 {
                            closedFences[number] = open.contentStart..<line.lowerBound
                        }
                        fence = nil
                    }
                }
                maskLine(number)
            } else if line.lowerBound < literalBlockEnd {
                mask(line.lowerBound..<min(literalBlockEnd, line.upperBound))
            } else if quote.contents.isEmpty {
                if line.upperBound < characters.count { visible[line.upperBound] = false }
                paragraphOpen = false
            } else {
                let block = quote.contents
                let terminal = atxLevel(block) != nil || isThematicBreak(block)
                let beginsBlock = terminal || beginsListItem(block) || previousQuoteDepth != quote.depth
                if beginsBlock, line.lowerBound > 0 { visible[line.lowerBound - 1] = false }
                let indented = contents.lowerBound - line.lowerBound >= 4
                    || characters[line.lowerBound..<contents.lowerBound].contains("\t")
                if indented, !paragraphOpen {
                    maskLine(number)
                } else {
                    if !indented, let marker = fenceMarker(block) {
                        fence = (marker.character, marker.length, quote.depth, min(line.upperBound + 1, characters.count))
                        paragraphOpen = false
                        maskLine(number)
                        continue
                    }
                    // Let inline parsing decide precedence except for a literal
                    // that may hide a fence while we are identifying blocks.
                    if nextFence < possibleFences.count,
                       let literal = continuedLiteral(in: block, through: possibleFences[nextFence]) {
                        literalBlockEnd = literal.upperBound
                        mask(literal.lowerBound..<line.upperBound)
                    }
                    if terminal, line.upperBound < characters.count {
                        visible[line.upperBound] = false
                    }
                    if literalBlockEnd > line.upperBound && !block.contains(where: { visible[$0] }) {
                        maskLine(number)
                        paragraphOpen = false
                    } else {
                        paragraphOpen = !terminal
                    }
                }
            }
            previousQuoteDepth = quote.depth
        }
    }

    mutating func maskInlineLiterals() {
        let closingRuns = backtickClosers(in: characters.indices)
        var index = 0
        while index < characters.count {
            guard visible[index] else {
                index += 1
                continue
            }
            let character = characters[index]
            if escapesNext(at: index, before: characters.count) {
                visible[index + 1] = false
                index += 2
            } else if character == Self.backtick {
                if let closer = closingRuns[index] {
                    mask(index..<closer.upperBound)
                    index = closer.upperBound
                } else {
                    index = run(of: Self.backtick, since: index, until: characters.count)
                }
            } else if (character == "<" || character == "%"), let end = literalEnd(start: index) {
                mask(index..<end)
                index = end
            } else {
                index += 1
            }
        }
    }

    private func backtickClosers(in range: Range<Int>) -> [Int: Range<Int>] {
        var nextRun: [Int: Range<Int>] = [:]
        var closingRuns: [Int: Range<Int>] = [:]
        var index = range.upperBound
        while index > range.lowerBound {
            index -= 1
            guard visible[index] else {
                if !nextRun.isEmpty { nextRun.removeAll(keepingCapacity: true) }
                continue
            }
            guard characters[index] == Self.backtick else { continue }
            let end = index + 1
            while index > range.lowerBound, visible[index - 1], characters[index - 1] == Self.backtick { index -= 1 }
            let length = end - index
            closingRuns[index] = nextRun[length]
            // A backslash can escape the first tick, leaving the remainder as a shorter opener.
            if length > 1, index > range.lowerBound, characters[index - 1] == "\\" {
                closingRuns[index + 1] = nextRun[length - 1]
            }
            nextRun[length] = index..<end
        }
        return closingRuns
    }

    private func continuedLiteral(in line: Range<Int>, through fence: Int) -> Range<Int>? {
        guard line.contains(where: { characters[$0] == "<" || characters[$0] == "%" }) else { return nil }
        let closingRuns = backtickClosers(in: line)
        var index = line.lowerBound
        while index < line.upperBound {
            let character = characters[index]
            if escapesNext(at: index, before: line.upperBound) {
                index += 2
            } else if character == Self.backtick {
                index = closingRuns[index]?.upperBound ?? run(of: character, since: index, until: line.upperBound)
            } else if (character == "<" || character == "%"), let end = literalEnd(start: index) {
                if end > fence { return index..<end }
                index = end
            } else {
                index += 1
            }
        }
        return nil
    }

    private func escapesNext(at index: Int, before end: Int) -> Bool {
        guard characters[index] == "\\", index + 1 < end, let byte = characters[index + 1].asciiValue else { return false }
        return (33...47).contains(byte) || (58...64).contains(byte)
            || (91...96).contains(byte) || (123...126).contains(byte)
    }

    func anchors(excluding definitions: Set<Int>) -> [MarkdownAnchor] {
        var headings: [Heading] = []
        var blocks: [MarkdownAnchor] = []
        var paragraph: Range<Int>?
        var precedingParagraph: Range<Int>?
        var precedingFence: Range<Int>?
        for (number, line) in lines.enumerated() {
            guard activeLines[number], !definitions.contains(number) else {
                paragraph = nil
                precedingParagraph = nil
                precedingFence = closedFences[number]
                continue
            }
            let contents = trimmed(line)
            if contents.isEmpty {
                if let paragraph { precedingParagraph = paragraph }
                paragraph = nil
                continue
            }
            let fence = precedingFence
            precedingFence = nil
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
                    bodyRange = paragraph ?? precedingParagraph ?? fence
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
        return (headingAnchors + blocks).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    func references() -> (destinations: [String: String], lines: Set<Int>) {
        var definitions: [String: String] = [:]
        var definitionLines: Set<Int> = []
        var paragraphOpen = false
        for (number, line) in lines.enumerated() {
            if !activeLines[number] || !line.contains(where: { visible[$0] && !characters[$0].isWhitespace }) {
                paragraphOpen = false
            } else if !paragraphOpen, let definition = referenceDefinition(in: line) {
                definitionLines.insert(number)
                if definitions[definition.label] == nil { definitions[definition.label] = definition.destination }
            } else {
                let contents = trimmed(line)
                paragraphOpen = atxLevel(contents) == nil && !isThematicBreak(contents)
                    && !(paragraphOpen && setextLevel(contents) != nil)
            }
        }
        return (definitions, definitionLines)
    }

    func links(
        in anchors: [MarkdownAnchor],
        references: (destinations: [String: String], lines: Set<Int>)
    ) -> [MarkdownLink] {
        let blocks = anchors.filter { $0.slug == nil }
        var nextBlock = 0
        var output: [MarkdownLink] = []
        for (number, line) in lines.enumerated() where activeLines[number] && !references.lines.contains(number) {
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
                    parsed = markdownLink(at: index, in: line, closingBrackets: closingBrackets, definitions: references.destinations)
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
              let close = closingBracket(from: start, before: contents.upperBound),
              !(start + 1..<close).contains(where: { visible[$0] && characters[$0] == "[" }),
              has(":", at: close + 1, before: contents.upperBound),
              let destination = destination(from: close + 2, before: contents.upperBound),
              !destination.value.isEmpty,
              destinationSuffixEnd(from: destination.end, before: contents.upperBound) == contents.upperBound else { return nil }
        let label = Self.referenceLabel(text((start + 1)..<close))
        guard !label.isEmpty else { return nil }
        return (label, destination.value)
    }

    private func inlineDestination(from start: Int, before end: Int) -> (value: String, end: Int)? {
        guard let parsed = destination(from: start, before: end),
              let cursor = destinationSuffixEnd(from: parsed.end, before: end),
              has(")", at: cursor, before: end) else { return nil }
        return (parsed.value, cursor + 1)
    }

    private func destinationSuffixEnd(from start: Int, before end: Int) -> Int? {
        var cursor = whitespaceEnd(from: start, before: end)
        if cursor > start, cursor < end, let close = titleDelimiter(characters[cursor]) {
            cursor += 1
            while cursor < end, !has(String(close), at: cursor, before: end) { cursor += 1 }
            guard cursor < end else { return nil }
            cursor = whitespaceEnd(from: cursor + 1, before: end)
        }
        return cursor
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
        guard let level = atxLevel(contents) else { return nil }
        let textStart = contents.lowerBound + level
        var title = trimmed(textStart..<contents.upperBound)
        var end = title.upperBound
        while end > title.lowerBound, has("#", at: end - 1, before: title.upperBound) { end -= 1 }
        if end > title.lowerBound, characters[end - 1].isWhitespace { title = trimmed(title.lowerBound..<end) }
        guard !title.isEmpty else { return nil }
        return Heading(title: text(title), start: start, level: level)
    }

    private func atxLevel(_ contents: Range<Int>) -> Int? {
        guard has("#", at: contents.lowerBound, before: contents.upperBound) else { return nil }
        let textStart = run(of: "#", since: contents.lowerBound, until: contents.upperBound)
        let level = textStart - contents.lowerBound
        guard level <= 6, textStart == contents.upperBound || characters[textStart].isWhitespace else { return nil }
        return level
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

    private func isThematicBreak(_ contents: Range<Int>) -> Bool {
        guard let first = contents.first, visible[first], "-*_".contains(characters[first]) else { return false }
        var count = 0
        for index in contents where !characters[index].isWhitespace {
            guard characters[index] == characters[first] else { return false }
            count += 1
        }
        return count >= 3
    }

    private func quoteContents(_ contents: Range<Int>) -> (contents: Range<Int>, depth: Int) {
        var start = contents.lowerBound
        var depth = 0
        while has(">", at: start, before: contents.upperBound) {
            depth += 1
            start = whitespaceEnd(from: start + 1, before: contents.upperBound)
        }
        return (start..<contents.upperBound, depth)
    }

    private func fenceMarker(_ contents: Range<Int>) -> (character: Character, length: Int)? {
        guard let first = contents.first else { return nil }
        let character = characters[first]
        guard character == "~" || character == Self.backtick else { return nil }
        let end = run(of: character, since: first, until: contents.upperBound)
        guard end - first >= 3, character == "~" || !characters[end..<contents.upperBound].contains(character) else { return nil }
        return (character, end - first)
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
        if isAngleDestination(at: start) { return nil }
        if matches("<!--", at: start, before: end) {
            return literalClose("-->", from: start + 4) ?? end
        }
        guard let tag = htmlTag(at: start) else { return nil }
        if !tag.closing, !tag.selfClosing, tag.name == "code" || tag.name == "pre" {
            let closingPrefix = "</" + tag.name
            if let close = (tag.end..<end).first(where: {
                matches(closingPrefix, at: $0, before: end, ignoringCase: true)
                    && htmlTag(at: $0)?.name == tag.name
            }) {
                return htmlTag(at: close)?.end
            }
            return end
        }
        return tag.end
    }

    private func isAngleDestination(at start: Int) -> Bool {
        guard characters[start] == "<" else { return false }
        var index = start
        while index > 0, characters[index - 1].isWhitespace, !characters[index - 1].isNewline { index -= 1 }
        return index >= 2 && characters[index - 2] == "]" && "(:".contains(characters[index - 1])
    }

    private func htmlTag(at start: Int) -> (name: String, end: Int, closing: Bool, selfClosing: Bool)? {
        let end = characters.count
        guard matches("<", at: start, before: end) else { return nil }
        let closing = matches("</", at: start, before: end)
        let nameStart = start + (closing ? 2 : 1)
        guard nameStart < end, characters[nameStart].isASCII, characters[nameStart].isLetter else { return nil }
        var cursor = nameStart + 1
        while cursor < end, characters[cursor].isASCII,
              characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "-" { cursor += 1 }
        let name = text(nameStart..<cursor).lowercased()
        while cursor < end {
            let attributeStart = whitespaceEnd(from: cursor, before: end)
            if matches(">", at: attributeStart, before: end) {
                return (name, attributeStart + 1, closing, false)
            }
            if !closing, matches("/>", at: attributeStart, before: end) {
                return (name, attributeStart + 2, false, true)
            }
            guard !closing, attributeStart > cursor, attributeStart < end,
                  isHTMLAttributeStart(characters[attributeStart]) else { return nil }
            cursor = attributeStart + 1
            while cursor < end, isHTMLAttributeStart(characters[cursor])
                || (characters[cursor].isASCII && characters[cursor].isNumber)
                || "-.".contains(characters[cursor]) { cursor += 1 }
            let assignment = whitespaceEnd(from: cursor, before: end)
            if matches("=", at: assignment, before: end) {
                let valueStart = whitespaceEnd(from: assignment + 1, before: end)
                guard let valueEnd = htmlAttributeValueEnd(from: valueStart) else { return nil }
                cursor = valueEnd
            }
        }
        return nil
    }

    private func isHTMLAttributeStart(_ character: Character) -> Bool {
        (character.isASCII && character.isLetter) || "_:".contains(character)
    }

    private func htmlAttributeValueEnd(from start: Int) -> Int? {
        let end = characters.count
        guard start < end else { return nil }
        let delimiter = characters[start]
        if delimiter == "\"" || delimiter == "'" {
            return ((start + 1)..<end).first { characters[$0] == delimiter }.map { $0 + 1 }
        }
        var cursor = start
        while cursor < end, !characters[cursor].isWhitespace,
              !"\"'=<>`".contains(characters[cursor]) { cursor += 1 }
        return start < cursor ? cursor : nil
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
