import Foundation

extension MetaBrainStore {
    /// Expands a body citation from the retained revision identified in the reference.
    /// A section request uses the containing Markdown section or the surrounding paragraph.
    /// If the full expansion exceeds the output budget, the result identifies the exact slice returned.
    public func getEvidence(
        _ reference: EvidenceReference,
        context: EvidenceContext? = nil,
        maxTokens: Int = EvidenceOutput.defaultMaxTokens
    ) async throws -> EvidenceOutput {
        guard maxTokens >= EvidenceOutput.minimumMaxTokens else {
            throw EvidenceError.invalidTokenBudget(maxTokens)
        }
        guard let document = try await getDocument(.documentID(reference.documentID), version: reference.version) else {
            throw MetaBrainStoreError.documentVersionNotFound(reference: reference.rawValue, version: reference.version)
        }

        let body = EvidenceBody(document.body)
        let markdown = document.isMarkdown && (context == .section || reference.needsMarkdown)
            ? MarkdownDocument(body: document.body, includeLinks: false) : nil
        let exact: Range<Int>
        do {
            exact = try reference.exactRange(body: body, markdown: markdown)
        } catch DocumentPassageError.ambiguousSelector {
            // The existing budgeted retrieval API groups unavailable block selectors together.
            throw EvidenceError.blockNotFound(reference)
        }

        let expanded = if context == .section {
            markdown?.section(containing: exact) ?? body.paragraph(containing: exact)
        } else {
            exact
        }

        func output(for range: Range<Int>, truncated: Bool) throws -> EvidenceOutput? {
            // Every extended grapheme cluster occupies at least one UTF-8 byte.
            guard range.count <= maxTokens else { return nil }
            let ref = range == exact ? reference : EvidenceReference(document: document, location: .range(range))
            let item = EvidenceItem(ref: ref, path: document.path.rawValue, text: body.text(in: range))
            let result = EvidenceOutput(items: [item], truncated: truncated)
            return try result.fits(maxTokens: maxTokens) ? result : nil
        }

        if let result = try output(for: expanded, truncated: false) { return result }
        if expanded != exact, let result = try output(for: exact, truncated: true) { return result }

        // A fixed-start prefix has a monotone encoded size: its text grows and its end offset gains digits.
        var result = EvidenceOutput(items: [], truncated: true)
        var lower = 1
        var upper = min(maxTokens, exact.count - 1)
        while lower <= upper {
            let length = lower + (upper - lower) / 2
            let prefix = exact.lowerBound..<(exact.lowerBound + length)
            if let candidate = try output(for: prefix, truncated: true) {
                result = candidate
                lower = length + 1
            } else {
                upper = length - 1
            }
        }
        return result
    }
}
