import Foundation

struct MetaBrainRecallCandidate: Sendable {
    private static let windowWidth = 240
    private static let openingWidth = 120
    private static let passagesPerDocument = 3

    private let result: RecallResult
    private let headerBytes: Int
    private let drafts: [PassageDraft]
    private let score: Double

    init?(
        document: StoredDocument,
        passages: [MetaBrainRankedPassage],
        weights: [String: Double],
        maxBytes: Int
    ) throws {
        let ranked = passages.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.chunk.ordinal < rhs.chunk.ordinal
        }
        guard let first = ranked.first else { return nil }

        var sources = document.references.compactMap { reference -> String? in
            guard case .externalURL(let url) = reference else { return nil }
            return url.absoluteString
        }
        if let source = document.metadata["source"], !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sources.append(source)
        }
        var seenSources: Set<String> = []
        let result = RecallResult(
            documentID: document.id.rawValue,
            path: document.path.rawValue,
            version: document.currentVersion,
            title: document.title,
            sources: sources.filter { seenSources.insert($0).inserted }
        )
        let headerBytes = try RecallResult.jsonEncoder().encode(result).count
        guard headerBytes <= maxBytes - RecallResult.minimumMaxBytes else { return nil }

        self.result = result
        self.headerBytes = headerBytes
        drafts = Self.passageDrafts(body: document.body, ranked: ranked, weights: weights)
        score = first.score
    }

    static func select(_ candidates: [Self], limit: Int, maxBytes: Int) throws -> [RecallResult] {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.result.documentID < rhs.result.documentID
        }
        let encoder = RecallResult.jsonEncoder()
        var selected: [Selection] = []
        var remaining = maxBytes - RecallResult.minimumMaxBytes

        // Charge each compact JSON object and its separators once. The array brackets and line feed are reserved above.
        for candidate in sorted {
            guard selected.count < limit else { break }
            let separator = selected.isEmpty ? 0 : 1
            guard candidate.headerBytes <= remaining - separator else { continue }

            var result = candidate.result
            var primaryBytes = 0
            if let first = candidate.drafts.first {
                let primary = first.passage(width: first.minimumWidth)
                primaryBytes = try encoder.encode(primary).count
                guard primaryBytes <= remaining - separator - candidate.headerBytes else { continue }
                result.passages.append(primary)
            }
            remaining -= separator + candidate.headerBytes + primaryBytes
            selected.append(Selection(result: result, drafts: candidate.drafts, primaryBytes: primaryBytes))
        }

        // Give each selected document a share of the remaining budget before considering more passages.
        for index in selected.indices {
            guard let draft = selected[index].drafts.first else { continue }
            let primaryBytes = selected[index].primaryBytes
            let share = remaining / (selected.count - index)
            if let (passage, bytes) = try draft.fitting(bytes: primaryBytes + share, encoder: encoder) {
                selected[index].result.passages[0] = passage
                remaining -= bytes - primaryBytes
            }
        }
        for position in 1..<passagesPerDocument {
            for index in selected.indices where selected[index].drafts.count > position {
                guard remaining > 1 else { break }
                let draft = selected[index].drafts[position]
                if let (passage, bytes) = try draft.fitting(bytes: remaining - 1, encoder: encoder) {
                    selected[index].result.passages.append(passage)
                    remaining -= bytes + 1
                }
            }
        }
        return selected.map { selection in
            var result = selection.result
            result.passages.sort { $0.start < $1.start }
            return result
        }
    }

    private static func passageDrafts(
        body: String,
        ranked: [MetaBrainRankedPassage],
        weights: [String: Double]
    ) -> [PassageDraft] {
        guard !body.isEmpty else { return [] }
        if !ranked.contains(where: \.hasBodyMatch) {
            return [PassageDraft(text: String(body.prefix(openingWidth)), start: 0, anchor: 0..<1)]
        }

        let bodyLength = body.count
        var windows: [(range: Range<Int>, anchor: Range<Int>)] = []
        for passage in ranked where passage.hasBodyMatch {
            guard windows.count < passagesPerDocument else { break }
            let chunk = passage.chunk
            guard let match = strongestMatch(in: chunk.text, weights: weights),
                  chunk.startOffset >= 0, chunk.startOffset <= bodyLength,
                  match.upperBound <= bodyLength - chunk.startOffset else { continue }

            let anchorWidth = min(match.count, windowWidth)
            let anchorStart = chunk.startOffset + match.lowerBound + (match.count - anchorWidth) / 2
            let anchor = anchorStart..<(anchorStart + anchorWidth)
            let range = window(around: anchor, within: bodyLength, width: min(windowWidth, bodyLength))
            let overlaps = windows.indices.filter { windows[$0].range.overlaps(range) }
            if let first = overlaps.first {
                let lower = overlaps.reduce(range.lowerBound) { min($0, windows[$1].range.lowerBound) }
                let upper = overlaps.reduce(range.upperBound) { max($0, windows[$1].range.upperBound) }
                if upper - lower <= 2 * windowWidth {
                    windows[first].range = lower..<upper
                    for index in overlaps.dropFirst().reversed() { windows.remove(at: index) }
                }
            } else {
                windows.append((range, anchor))
            }
        }

        return windows.map { window in
            let lower = body.index(body.startIndex, offsetBy: window.range.lowerBound)
            let upper = body.index(lower, offsetBy: window.range.count)
            let anchor = (window.anchor.lowerBound - window.range.lowerBound)..<(window.anchor.upperBound - window.range.lowerBound)
            return PassageDraft(text: String(body[lower..<upper]), start: window.range.lowerBound, anchor: anchor)
        }
    }

    private static func strongestMatch(in text: String, weights: [String: Double]) -> Range<Int>? {
        var best: MetaBrainSearchMatch?
        MetaBrainSearchMatch.forEach(in: text, weights: weights) { match in
            if match.weight > (best?.weight ?? -.infinity) { best = match }
        }
        return best?.range
    }

    private static func window(around anchor: Range<Int>, within length: Int, width: Int) -> Range<Int> {
        let start = max(0, min(anchor.lowerBound - (width - anchor.count) / 2, length - width))
        return start..<(start + width)
    }

    private struct Selection {
        var result: RecallResult
        let drafts: [PassageDraft]
        let primaryBytes: Int
    }

    private struct PassageDraft: Sendable {
        let text: String
        let start: Int
        let anchor: Range<Int>

        var minimumWidth: Int { anchor.count }

        func passage(width: Int) -> RecallPassage {
            let range = window(around: anchor, within: text.count, width: width)
            let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
            let upper = text.index(lower, offsetBy: range.count)
            return RecallPassage(start: start + range.lowerBound, end: start + range.upperBound, text: String(text[lower..<upper]))
        }

        func fitting(bytes: Int, encoder: JSONEncoder) throws -> (RecallPassage, Int)? {
            var lower = minimumWidth
            var upper = text.count
            var best: (RecallPassage, Int)?
            while lower <= upper {
                let width = lower + (upper - lower) / 2
                let candidate = passage(width: width)
                let size = try encoder.encode(candidate).count
                if size <= bytes {
                    best = (candidate, size)
                    lower = width + 1
                } else {
                    upper = width - 1
                }
            }
            return best
        }
    }
}
