import Foundation

enum MetaBrainKeyspace {
    static let sequenceWidth = 20
    static let ordinalWidth = 10

    static func document(id: DocumentID) -> String {
        "doc/id/\(id.rawValue)"
    }

    static func documentPath(_ path: DocumentPath) -> String {
        "doc/path/\(path.rawValue)"
    }

    static func documentPathDescendantPrefix(_ path: DocumentPath) -> String {
        documentPath(path) + "/"
    }

    static func version(id: DocumentID, sequence: UInt64) -> String {
        "ver/\(id.rawValue)/\(padded(sequence, width: sequenceWidth))"
    }

    static func currentChunk(id: DocumentID, ordinal: UInt32) -> String {
        "chunk/current/\(id.rawValue)/\(padded(UInt64(ordinal), width: ordinalWidth))"
    }

    static func currentChunkPrefix(id: DocumentID) -> String {
        "chunk/current/\(id.rawValue)/"
    }

    static func term(_ term: String, id: DocumentID, ordinal: UInt32) -> String {
        "idx/term/\(component(term))/\(id.rawValue)/\(padded(UInt64(ordinal), width: ordinalWidth))"
    }

    static func termPrefix(_ term: String) -> String {
        "idx/term/\(component(term))/"
    }

    static func tag(_ tag: String, id: DocumentID) -> String {
        "idx/tag/\(component(tag))/\(id.rawValue)"
    }

    static func tagPrefix(_ tag: String) -> String {
        "idx/tag/\(component(tag))/"
    }

    static func metadata(key: String, value: String, id: DocumentID) -> String {
        "idx/meta/\(component(key))/\(component(value))/\(id.rawValue)"
    }

    static func metadataPrefix(key: String, value: String) -> String {
        "idx/meta/\(component(key))/\(component(value))/"
    }

    static func outboundReference(sourceID: DocumentID, targetID: DocumentID) -> String {
        "idx/ref/out/\(sourceID.rawValue)/\(targetID.rawValue)"
    }

    static func outboundReferencePrefix(sourceID: DocumentID) -> String {
        "idx/ref/out/\(sourceID.rawValue)/"
    }

    static func inboundReference(targetID: DocumentID, sourceID: DocumentID) -> String {
        "idx/ref/in/\(targetID.rawValue)/\(sourceID.rawValue)"
    }

    static func inboundReferencePrefix(targetID: DocumentID) -> String {
        "idx/ref/in/\(targetID.rawValue)/"
    }

    static func tree(parentPath: DocumentPath, name: String) -> String {
        "tree/\(component(parentPath.rawValue))/\(component(name))"
    }

    static func treePrefix(parentPath: DocumentPath) -> String {
        "tree/\(component(parentPath.rawValue))/"
    }

    static func prefix(_ family: KeyFamily) -> String {
        family.rawValue
    }

    private static func padded(_ value: UInt64, width: Int) -> String {
        String(format: "%0\(width)llu", value)
    }

    private static func component(_ value: String) -> String {
        var output = ""

        for scalar in value.lowercased().unicodeScalars {
            if isUnescapedComponentScalar(scalar) {
                output.unicodeScalars.append(scalar)
            } else {
                let bytes = String(scalar).utf8
                for byte in bytes {
                    output += String(format: "%%%02X", byte)
                }
            }
        }

        return output
    }

    private static func isUnescapedComponentScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar == "-" || scalar == "_" || scalar == "." ||
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 97 && scalar.value <= 122)
    }
}

extension MetaBrainKeyspace {
    enum KeyFamily: String {
        case documentID = "doc/id/"
        case documentPath = "doc/path/"
        case version = "ver/"
        case currentChunk = "chunk/current/"
        case term = "idx/term/"
        case tag = "idx/tag/"
        case metadata = "idx/meta/"
        case outboundReference = "idx/ref/out/"
        case inboundReference = "idx/ref/in/"
        case tree = "tree/"
    }
}
