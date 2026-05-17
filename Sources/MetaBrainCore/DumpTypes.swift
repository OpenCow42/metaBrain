import Foundation

public enum DocumentDumpVersionSelection: String, Codable, Equatable, Sendable {
    case current
    case allRetained
}

public struct DocumentDumpQuery: Codable, Equatable, Sendable {
    public var path: DocumentPath
    public var versionSelection: DocumentDumpVersionSelection

    public init(
        path: DocumentPath,
        versionSelection: DocumentDumpVersionSelection = .current
    ) {
        self.path = path
        self.versionSelection = versionSelection
    }
}

public enum DocumentDumpReferenceKind: String, Codable, Equatable, Sendable {
    case documentID
    case path
    case externalURL
}

public struct DocumentDumpReference: Codable, Equatable, Sendable {
    public var kind: DocumentDumpReferenceKind
    public var value: String

    public init(kind: DocumentDumpReferenceKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public init(_ reference: DocumentReference) {
        switch reference {
        case .documentID(let id):
            self.init(kind: .documentID, value: id.rawValue)
        case .path(let path):
            self.init(kind: .path, value: path.rawValue)
        case .externalURL(let url):
            self.init(kind: .externalURL, value: url.absoluteString)
        }
    }
}

public struct DocumentDumpEntry: Encodable, Equatable, Sendable {
    public var documentID: DocumentID
    public var path: DocumentPath
    public var title: String?
    public var body: String
    public var version: UInt64
    public var versionCreatedAt: Date
    public var isCurrent: Bool
    public var tags: [String]
    public var metadata: [String: String]
    public var references: [DocumentDumpReference]
    public var bodyCharacterCount: Int
    public var bodyUTF8ByteCount: Int
    public var fileSystemPath: String?

    public init(
        documentID: DocumentID,
        path: DocumentPath,
        title: String?,
        body: String,
        version: UInt64,
        versionCreatedAt: Date,
        isCurrent: Bool,
        tags: [String],
        metadata: [String: String],
        references: [DocumentDumpReference],
        fileSystemPath: String? = nil
    ) {
        self.documentID = documentID
        self.path = path
        self.title = title
        self.body = body
        self.version = version
        self.versionCreatedAt = versionCreatedAt
        self.isCurrent = isCurrent
        self.tags = tags
        self.metadata = metadata
        self.references = references
        self.bodyCharacterCount = body.count
        self.bodyUTF8ByteCount = body.utf8.count
        self.fileSystemPath = fileSystemPath
    }

    private enum CodingKeys: String, CodingKey {
        case documentID
        case path
        case title
        case body
        case version
        case versionCreatedAt
        case isCurrent
        case tags
        case metadata
        case references
        case bodyCharacterCount
        case bodyUTF8ByteCount
        case fileSystemPath
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documentID.rawValue, forKey: .documentID)
        try container.encode(path.rawValue, forKey: .path)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(version, forKey: .version)
        try container.encode(versionCreatedAt, forKey: .versionCreatedAt)
        try container.encode(isCurrent, forKey: .isCurrent)
        try container.encode(tags, forKey: .tags)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(references, forKey: .references)
        try container.encode(bodyCharacterCount, forKey: .bodyCharacterCount)
        try container.encode(bodyUTF8ByteCount, forKey: .bodyUTF8ByteCount)
        try container.encodeIfPresent(fileSystemPath, forKey: .fileSystemPath)
    }
}

public struct DocumentDumpFileWriter {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func write(
        _ entries: [DocumentDumpEntry],
        to outputDirectory: URL
    ) throws -> [DocumentDumpEntry] {
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        return try entries.map { entry in
            let fileURL = Self.destinationURL(for: entry, in: outputDirectory)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.body.write(to: fileURL, atomically: true, encoding: .utf8)

            var copiedEntry = entry
            copiedEntry.fileSystemPath = fileURL.path
            return copiedEntry
        }
    }

    public static func destinationURL(
        for entry: DocumentDumpEntry,
        in outputDirectory: URL
    ) -> URL {
        let components = pathComponents(for: entry.path)
        let parentComponents = components.dropLast()
        let rawFileName = components.last!
        let splitName = splitFileName(rawFileName)
        let versionStamp = utcFileStamp(for: entry.versionCreatedAt)
        let fileName = "\(splitName.base)__\(entry.documentID.rawValue)__v\(entry.version)__\(versionStamp)\(splitName.extension)"

        return parentComponents.reduce(outputDirectory) { url, component in
            url.appendingPathComponent(fileSystemSafeComponent(component), isDirectory: true)
        }.appendingPathComponent(fileSystemSafeComponent(fileName), isDirectory: false)
    }

    private static func pathComponents(for path: DocumentPath) -> [String] {
        let components = path.rawValue
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return components.isEmpty ? ["root"] : components
    }

    private static func splitFileName(_ fileName: String) -> (base: String, extension: String) {
        guard let dotIndex = fileName.lastIndex(of: "."),
              dotIndex != fileName.startIndex,
              dotIndex != fileName.index(before: fileName.endIndex) else {
            return (fileName, ".txt")
        }

        return (
            String(fileName[..<dotIndex]),
            String(fileName[dotIndex...])
        )
    }

    private static func fileSystemSafeComponent(_ component: String) -> String {
        let scalars = component.unicodeScalars.map { scalar in
            if scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                return "_"
            }

            return String(scalar)
        }
        return scalars.joined()
    }

    private static func utcFileStamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )

        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year!,
            parts.month!,
            parts.day!,
            parts.hour!,
            parts.minute!,
            parts.second!
        )
    }
}
