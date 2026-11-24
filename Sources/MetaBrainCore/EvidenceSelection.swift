import Foundation

struct EvidenceSearchCandidate: Sendable {
    private static let maximumPassages = 3
    private static let maximumMergedCharacters = 480

    let score: Double
    let documentID: DocumentID
    private let hits: [EvidenceHit]

    init(document: StoredDocument, reference: EvidenceReference) {
        score = 0
        documentID = document.id
        hits = [EvidenceHit(full: EvidenceItem(ref: reference, path: document.path.rawValue), compact: nil)]
    }

    init(document: StoredDocument, passages: [MetaBrainRankedPassage], weights: [String: Double], view: EvidenceSearchView) {
        let body = EvidenceBody(document.body)
        let ranked = passages.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.chunk.ordinal < rhs.chunk.ordinal
        }
        var windows: [EvidenceWindow] = []
        for passage in ranked where passage.hasBodyMatch {
            let chunk = passage.chunk
            guard (0...body.count).contains(chunk.startOffset) else { continue }
            var matches: [MetaBrainSearchMatch] = []
            MetaBrainSearchMatch.forEach(in: chunk.text, weights: weights) { matches.append($0) }
            matches.sort {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return $0.range.lowerBound < $1.range.lowerBound
            }
            for match in matches where match.range.upperBound <= body.count - chunk.startOffset {
                let anchor = (chunk.startOffset + match.range.lowerBound)..<(chunk.startOffset + match.range.upperBound)
                if windows.contains(where: { $0.full.lowerBound <= anchor.lowerBound && anchor.upperBound <= $0.full.upperBound }) {
                    continue
                }
                Self.add(body.excerpt(around: anchor), to: &windows)
            }
        }
        if windows.isEmpty { windows = [EvidenceWindow(full: body.opening, compact: body.opening)] }

        func item(for range: Range<Int>) -> EvidenceItem {
            EvidenceItem(
                ref: EvidenceReference(document: document, location: .range(range)),
                path: document.path.rawValue,
                text: view == .evidence ? body.text(in: range) : nil
            )
        }
        score = ranked.first?.score ?? 0
        documentID = document.id
        hits = windows.map { window in
            EvidenceHit(full: item(for: window.full), compact: window.compact != window.full && view == .evidence
                ? item(for: window.compact) : nil)
        }
    }

    private static func add(_ window: EvidenceWindow, to windows: inout [EvidenceWindow]) {
        let overlapping = windows.indices.filter { windows[$0].full.overlaps(window.full) }
        if let first = overlapping.first {
            let start = overlapping.reduce(window.full.lowerBound) { min($0, windows[$1].full.lowerBound) }
            let end = overlapping.reduce(window.full.upperBound) { max($0, windows[$1].full.upperBound) }
            guard end - start <= maximumMergedCharacters else { return }
            windows[first].full = start..<end
            for index in overlapping.dropFirst().reversed() { windows.remove(at: index) }
        } else if windows.count < maximumPassages {
            windows.append(window)
        }
    }

    static func select(_ candidates: [Self], limit: Int, maxTokens: Int) throws -> EvidenceOutput {
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.score == 0, lhs.hits[0].full.path != rhs.hits[0].full.path {
                return lhs.hits[0].full.path < rhs.hits[0].full.path
            }
            return lhs.documentID < rhs.documentID
        }
        var output = EvidenceBudget(maxTokens: maxTokens, truncated: ranked.count > limit)
        var selected: [Self] = []
        for candidate in ranked {
            guard selected.count < limit else { break }
            if try output.append(candidate.hits[0]) { selected.append(candidate) }
        }
        // Give each document a citation before spending the remaining budget on more matches.
        for position in 1..<maximumPassages {
            for candidate in selected where candidate.hits.count > position {
                _ = try output.append(candidate.hits[position])
            }
        }
        return output.result
    }
}

private struct EvidenceHit: Sendable {
    let full: EvidenceItem
    let compact: EvidenceItem?
}

struct EvidenceWindow {
    var full: Range<Int>
    let compact: Range<Int>
}

struct EvidenceBody {
    private static let contextCharacters = 200
    private static let qualifierWords: Set<String> = [
        "although", "applies", "but", "caution", "caveat", "constraint", "except", "excludes", "however", "if",
        "important", "limit", "limited", "never", "note", "only", "provided", "restriction", "subject", "unless",
        "until", "warning", "when", "where", "while", "yet"
    ]
    private let characters: [Character]

    init(_ body: String) {
        characters = Array(body)
    }

    var count: Int { characters.count }

    var opening: Range<Int> {
        let limit = min(120, count)
        let start = trimmed(0..<limit).lowerBound
        return trimmed(start..<unitEnd(from: min(start + 1, limit), through: limit))
    }

    func text(in range: Range<Int>) -> String { String(characters[range]) }

    func excerpt(around anchor: Range<Int>) -> EvidenceWindow {
        let lowerLimit = max(0, anchor.lowerBound - Self.contextCharacters)
        let upperLimit = anchor.upperBound + min(Self.contextCharacters, count - anchor.upperBound)
        var start = unitStart(from: anchor.lowerBound, through: lowerLimit)
        var end = unitEnd(from: anchor.upperBound, through: upperLimit)
        var compactStart = start
        var compactEnd = end

        // Keep one neighboring unit on each side so nearby qualifications survive extraction.
        let previous = trimmed(lowerLimit..<start)
        if !previous.isEmpty {
            let preceding = unitStart(from: previous.upperBound - 1, through: lowerLimit)
            if preceding > lowerLimit || lowerLimit == 0 {
                start = preceding
                if isQualifier(preceding..<previous.upperBound) { compactStart = start }
            }
        }
        let next = trimmed(end..<upperLimit).lowerBound
        if next < upperLimit {
            let following = unitEnd(from: next + 1, through: upperLimit)
            if following < upperLimit || upperLimit == count {
                end = following
                // Short consecutive prose can qualify a claim without a cue such as "however".
                if isQualifier(next..<following) || (following - next <= 120 && !"#^".contains(characters[next])) {
                    compactEnd = end
                }
            }
        }
        return EvidenceWindow(full: trimmed(start..<end), compact: trimmed(compactStart..<compactEnd))
    }

    func paragraph(containing range: Range<Int>) -> Range<Int> {
        var start = range.lowerBound
        while start > 0, !isBlankLineEnd(at: start - 1) { start -= 1 }

        var end = range.upperBound
        while end < count, !isBlankLineEnd(at: end) { end += 1 }

        let paragraph = trimmed(start..<end)
        return min(paragraph.lowerBound, range.lowerBound)..<max(paragraph.upperBound, range.upperBound)
    }

    private func isBlankLineEnd(at offset: Int) -> Bool {
        guard characters[offset].isNewline else { return false }
        var index = offset
        while index > 0, characters[index - 1].isWhitespace {
            index -= 1
            if characters[index].isNewline { return true }
        }
        return false
    }

    private func unitStart(from offset: Int, through limit: Int) -> Int {
        var index = offset
        while index > limit, !endsUnit(at: index - 1) { index -= 1 }
        return index
    }

    private func unitEnd(from offset: Int, through limit: Int) -> Int {
        var index = offset
        while index < limit, index == 0 || !endsUnit(at: index - 1) { index += 1 }
        return index
    }

    private func endsUnit(at offset: Int) -> Bool {
        let character = characters[offset]
        if character.isNewline { return true }
        guard offset == count - 1 || characters[offset + 1].isWhitespace else { return false }
        if ".!?".contains(character) { return true }
        return offset > 0 && "\"'”’)]".contains(character) && ".!?".contains(characters[offset - 1])
    }

    private func isQualifier(_ range: Range<Int>) -> Bool {
        let words = MetaBrainStore.tokenize(text(in: range))
        return words.prefix(8).contains(where: Self.qualifierWords.contains)
    }

    private func trimmed(_ range: Range<Int>) -> Range<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end, characters[start].isWhitespace { start += 1 }
        while start < end, characters[end - 1].isWhitespace { end -= 1 }
        return start..<end
    }
}

/// Measures each selected JSON object once and accounts for brackets, commas, the status field, and the final LF.
private struct EvidenceBudget {
    private let encoder = RecallResult.jsonEncoder()
    private var items: [EvidenceItem] = []
    private var remaining: Int
    private var truncated: Bool

    init(maxTokens: Int, truncated: Bool) {
        self.truncated = truncated
        // The JSON spelling of true is one byte shorter than false.
        remaining = maxTokens - EvidenceOutput.minimumMaxTokens + (truncated ? 1 : 0)
    }

    var result: EvidenceOutput { EvidenceOutput(items: items, truncated: truncated) }

    mutating func append(_ hit: EvidenceHit) throws -> Bool {
        if try appendItem(hit.full) { return true }
        if let compact = hit.compact { return try appendItem(compact) }
        return false
    }

    private mutating func appendItem(_ item: EvidenceItem) throws -> Bool {
        let bytes = try encoder.encode(item).count + (items.isEmpty ? 0 : 1)
        guard bytes <= remaining else {
            if !truncated {
                truncated = true
                remaining += 1
            }
            return false
        }
        items.append(item)
        remaining -= bytes
        return true
    }
}
