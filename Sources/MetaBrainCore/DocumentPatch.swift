import Foundation

public struct DocumentPatchRequest: Codable, Equatable, Sendable {
    public var reference: DocumentReference
    public var unifiedDiff: String
    public var retention: VersionRetentionPolicy?

    public init(
        reference: DocumentReference,
        unifiedDiff: String,
        retention: VersionRetentionPolicy? = nil
    ) {
        self.reference = reference
        self.unifiedDiff = unifiedDiff
        self.retention = retention
    }
}

public enum MetaBrainPatchError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case documentNotFound
    case noHunks
    case multipleFilesUnsupported
    case unsupportedPatch(String)
    case malformedFileHeader(line: Int)
    case malformedHunkHeader(line: Int, text: String)
    case malformedHunkBody(line: Int, text: String)
    case hunkLineCountMismatch(line: Int)
    case hunkOutOfOrder(line: Int)
    case hunkOutOfRange(line: Int)
    case contextMismatch(line: Int, expected: String, actual: String?)

    public var description: String {
        switch self {
        case .documentNotFound:
            "Document not found."
        case .noHunks:
            "Patch does not contain any hunks."
        case .multipleFilesUnsupported:
            "Patch must update exactly one file."
        case .unsupportedPatch(let reason):
            "Unsupported patch: \(reason)."
        case .malformedFileHeader(let line):
            "Malformed file header at patch line \(line)."
        case .malformedHunkHeader(let line, let text):
            "Malformed hunk header at patch line \(line): \(text)"
        case .malformedHunkBody(let line, let text):
            "Malformed hunk body at patch line \(line): \(text)"
        case .hunkLineCountMismatch(let line):
            "Hunk line counts do not match the header at patch line \(line)."
        case .hunkOutOfOrder(let line):
            "Hunk starts before the previous hunk ended at patch line \(line)."
        case .hunkOutOfRange(let line):
            "Hunk starts outside the document body at patch line \(line)."
        case .contextMismatch(let line, let expected, let actual):
            if let actual {
                "Patch context mismatch at patch line \(line): expected '\(expected)', found '\(actual)'."
            } else {
                "Patch context mismatch at patch line \(line): expected '\(expected)', found end of document."
            }
        }
    }

    public var errorDescription: String? {
        description
    }
}

struct UnifiedTextPatch: Equatable, Sendable {
    private var hunks: [UnifiedTextHunk]

    init(_ text: String) throws {
        hunks = try Self.parse(text)
    }

    func applying(to body: String) throws -> String {
        let original = PatchTextLine.split(body)
        var result: [PatchTextLine] = []
        var cursor = 0

        for hunk in hunks {
            let startIndex = hunk.startIndex
            guard startIndex >= cursor else {
                throw MetaBrainPatchError.hunkOutOfOrder(line: hunk.patchLine)
            }
            guard startIndex <= original.count else {
                throw MetaBrainPatchError.hunkOutOfRange(line: hunk.patchLine)
            }

            result.append(contentsOf: original[cursor..<startIndex])
            var originalIndex = startIndex

            for operation in hunk.operations {
                switch operation {
                case .context(let line, let patchLine):
                    try Self.require(line, at: originalIndex, in: original, patchLine: patchLine)
                    result.append(original[originalIndex])
                    originalIndex += 1

                case .deletion(let line, let patchLine):
                    try Self.require(line, at: originalIndex, in: original, patchLine: patchLine)
                    originalIndex += 1

                case .insertion(let line):
                    result.append(line)
                }
            }

            cursor = originalIndex
        }

        result.append(contentsOf: original[cursor..<original.count])
        return PatchTextLine.join(result)
    }

    private static func require(
        _ expected: PatchTextLine,
        at index: Int,
        in original: [PatchTextLine],
        patchLine: Int
    ) throws {
        guard index < original.count else {
            throw MetaBrainPatchError.contextMismatch(
                line: patchLine,
                expected: expected.content,
                actual: nil
            )
        }

        guard original[index] == expected else {
            throw MetaBrainPatchError.contextMismatch(
                line: patchLine,
                expected: expected.content,
                actual: original[index].content
            )
        }
    }

    private static func parse(_ text: String) throws -> [UnifiedTextHunk] {
        let lines = patchLines(from: text)
        var index = 0
        var diffHeaderCount = 0
        var fileHeaderCount = 0
        var hunks: [UnifiedTextHunk] = []

        while index < lines.count {
            let line = lines[index]

            if line.hasPrefix("diff --git ") {
                diffHeaderCount += 1
                if diffHeaderCount > 1 || !hunks.isEmpty {
                    throw MetaBrainPatchError.multipleFilesUnsupported
                }
                index += 1
                continue
            }

            if line.hasPrefix("--- ") {
                fileHeaderCount += 1
                if fileHeaderCount > 1 || !hunks.isEmpty {
                    throw MetaBrainPatchError.multipleFilesUnsupported
                }
                guard index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") else {
                    throw MetaBrainPatchError.malformedFileHeader(line: index + 1)
                }
                index += 2
                continue
            }

            if line.hasPrefix("@@ ") {
                let parsed = try parseHunk(startingAt: index, in: lines)
                hunks.append(parsed.hunk)
                index = parsed.nextIndex
                continue
            }

            if let reason = unsupportedReason(for: line) {
                throw MetaBrainPatchError.unsupportedPatch(reason)
            }

            if !hunks.isEmpty, isLooseHunkBodyLine(line) {
                throw MetaBrainPatchError.malformedHunkBody(line: index + 1, text: line)
            }

            index += 1
        }

        guard !hunks.isEmpty else {
            throw MetaBrainPatchError.noHunks
        }

        return hunks
    }

    private static func patchLines(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }

    private static func unsupportedReason(for line: String) -> String? {
        if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
            return "binary patches are not supported"
        }

        let unsupportedPrefixes = [
            "old mode ",
            "new mode ",
            "deleted file mode ",
            "new file mode ",
            "rename from ",
            "rename to ",
            "copy from ",
            "copy to ",
            "similarity index ",
            "dissimilarity index "
        ]

        return unsupportedPrefixes.first { line.hasPrefix($0) }.map { prefix in
            String(prefix.dropLast())
        }
    }

    private static func isLooseHunkBodyLine(_ line: String) -> Bool {
        guard let first = line.first else {
            return false
        }

        return first == " " || first == "+" || first == "-" || first == "\\"
    }

    private static func parseHunk(
        startingAt headerIndex: Int,
        in lines: [String]
    ) throws -> (hunk: UnifiedTextHunk, nextIndex: Int) {
        let header = lines[headerIndex]
        let headerLine = headerIndex + 1
        let range = try parseHunkRange(header, line: headerLine)
        var operations: [UnifiedTextOperation] = []
        var oldSeen = 0
        var newSeen = 0
        var index = headerIndex + 1

        while oldSeen < range.oldCount || newSeen < range.newCount {
            guard index < lines.count else {
                throw MetaBrainPatchError.hunkLineCountMismatch(line: headerLine)
            }

            let line = lines[index]
            guard let prefix = line.first else {
                throw MetaBrainPatchError.malformedHunkBody(line: index + 1, text: line)
            }

            let content = String(line.dropFirst())
            let patchLine = index + 1
            switch prefix {
            case " ":
                operations.append(.context(PatchTextLine(content: content, hasNewline: true), patchLine: patchLine))
                oldSeen += 1
                newSeen += 1
            case "-":
                operations.append(.deletion(PatchTextLine(content: content, hasNewline: true), patchLine: patchLine))
                oldSeen += 1
            case "+":
                operations.append(.insertion(PatchTextLine(content: content, hasNewline: true)))
                newSeen += 1
            default:
                throw MetaBrainPatchError.malformedHunkBody(line: patchLine, text: line)
            }

            index += 1
            if index < lines.count, lines[index] == "\\ No newline at end of file" {
                var previous = operations.removeLast()
                previous.markNoNewlineAtEndOfFile()
                operations.append(previous)
                index += 1
            }
        }

        if index < lines.count, isLooseHunkBodyLine(lines[index]), !lines[index].hasPrefix("@@ ") {
            throw MetaBrainPatchError.hunkLineCountMismatch(line: headerLine)
        }

        return (
            hunk: UnifiedTextHunk(
                patchLine: headerLine,
                oldStart: range.oldStart,
                oldCount: range.oldCount,
                operations: operations
            ),
            nextIndex: index
        )
    }

    private static func parseHunkRange(
        _ header: String,
        line: Int
    ) throws -> (oldStart: Int, oldCount: Int, newCount: Int) {
        guard header.hasPrefix("@@ "),
              let closingRange = header.range(
                of: " @@",
                range: header.index(header.startIndex, offsetBy: 3)..<header.endIndex
              ) else {
            throw MetaBrainPatchError.malformedHunkHeader(line: line, text: header)
        }

        let rangeText = header[header.index(header.startIndex, offsetBy: 3)..<closingRange.lowerBound]
        let parts = rangeText.split(separator: " ")
        guard parts.count == 2,
              let oldRange = parseRange(parts[0], prefix: "-"),
              let newRange = parseRange(parts[1], prefix: "+") else {
            throw MetaBrainPatchError.malformedHunkHeader(line: line, text: header)
        }

        return (
            oldStart: oldRange.start,
            oldCount: oldRange.count,
            newCount: newRange.count
        )
    }

    private static func parseRange(
        _ text: Substring,
        prefix: Character
    ) -> (start: Int, count: Int)? {
        guard text.first == prefix else {
            return nil
        }

        let value = text.dropFirst()
        let parts = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(parts[0]), start >= 0 else {
            return nil
        }

        if parts.count == 1 {
            return (start: start, count: 1)
        }

        guard let count = Int(parts[1]), count >= 0 else {
            return nil
        }

        return (start: start, count: count)
    }
}

private struct UnifiedTextHunk: Equatable, Sendable {
    var patchLine: Int
    var oldStart: Int
    var oldCount: Int
    var operations: [UnifiedTextOperation]

    var startIndex: Int {
        if oldCount == 0 {
            return max(0, oldStart - 1)
        }

        return oldStart - 1
    }
}

private enum UnifiedTextOperation: Equatable, Sendable {
    case context(PatchTextLine, patchLine: Int)
    case deletion(PatchTextLine, patchLine: Int)
    case insertion(PatchTextLine)

    mutating func markNoNewlineAtEndOfFile() {
        switch self {
        case .context(var line, let patchLine):
            line.hasNewline = false
            self = .context(line, patchLine: patchLine)
        case .deletion(var line, let patchLine):
            line.hasNewline = false
            self = .deletion(line, patchLine: patchLine)
        case .insertion(var line):
            line.hasNewline = false
            self = .insertion(line)
        }
    }
}

private struct PatchTextLine: Equatable, Sendable {
    var content: String
    var hasNewline: Bool

    static func split(_ text: String) -> [PatchTextLine] {
        guard !text.isEmpty else {
            return []
        }

        var lines: [PatchTextLine] = []
        var current = ""
        for character in text {
            if character == "\n" {
                lines.append(PatchTextLine(content: current, hasNewline: true))
                current = ""
            } else {
                current.append(character)
            }
        }

        if !text.hasSuffix("\n") {
            lines.append(PatchTextLine(content: current, hasNewline: false))
        }

        return lines
    }

    static func join(_ lines: [PatchTextLine]) -> String {
        lines.reduce(into: "") { output, line in
            output += line.content
            if line.hasNewline {
                output += "\n"
            }
        }
    }
}
