import Foundation

struct MetaBrainRankedPassage: Sendable {
    let chunk: MetaBrainChunkRecord
    let hasBodyMatch: Bool
    let score: Double
}

struct MetaBrainSearchMatch {
    let range: Range<Int>
    let weight: Double

    static func forEach(in text: String, weights: [String: Double], visit: (Self) -> Void) {
        var token = ""
        var start = 0
        var end = 0

        func finishToken() {
            if let weight = weights[token.lowercased()] {
                visit(Self(range: start..<end, weight: weight))
            }
            token.removeAll(keepingCapacity: true)
        }

        for (offset, character) in text.enumerated() {
            for scalar in character.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    if token.isEmpty { start = offset }
                    end = offset + 1
                    token.unicodeScalars.append(scalar)
                } else if !token.isEmpty {
                    finishToken()
                }
            }
        }
        if !token.isEmpty { finishToken() }
    }
}

struct MetaBrainSearchRanking: Sendable {
    let terms: [String]
    let weights: [String: Double]

    static func inverseDocumentFrequency(corpusSize: Int, documentFrequency: Int) -> Double {
        // The corpus count and postings can be observed on opposite sides of a concurrent write.
        let total = Double(max(corpusSize, documentFrequency))
        let matching = Double(documentFrequency)
        return log1p((total - matching + 0.5) / (matching + 0.5))
    }

    func termFrequencies(in text: String) -> [String: Int] {
        var frequencies: [String: Int] = [:]
        for term in MetaBrainStore.tokenize(text) where weights[term] != nil {
            frequencies[term, default: 0] += 1
        }
        return frequencies
    }

    func fieldFrequencies(title: String?, path: DocumentPath) -> [String: Double] {
        var fields: [String: Double] = [:]
        if let title {
            for (term, count) in termFrequencies(in: title) {
                fields[term, default: 0] += 4 * Double(count)
            }
        }
        for (term, count) in termFrequencies(in: path.rawValue) {
            fields[term, default: 0] += 2 * Double(count)
        }
        return fields
    }

    func score(fields: [String: Double], body: [String: Int]) -> Double {
        let saturation = 0.8
        return terms.reduce(0) { score, term in
            let frequency = fields[term, default: 0] + Double(body[term, default: 0])
            return score + weights[term, default: 0] * frequency * (saturation + 1) / (frequency + saturation)
        }
    }
}
