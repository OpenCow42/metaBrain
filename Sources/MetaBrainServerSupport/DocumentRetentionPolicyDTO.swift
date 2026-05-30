import Foundation
import MetaBrainCore

public enum DocumentRetentionPolicyDTOKind: String, Codable, Equatable, Sendable {
    case keepAll
    case keepLast
    case keepWithin
}

public struct DocumentRetentionPolicyDTO: Codable, Equatable, Sendable {
    public var kind: DocumentRetentionPolicyDTOKind
    public var count: Int?
    public var seconds: TimeInterval?

    public init(
        kind: DocumentRetentionPolicyDTOKind,
        count: Int? = nil,
        seconds: TimeInterval? = nil
    ) {
        self.kind = kind
        self.count = count
        self.seconds = seconds
    }

    public init(_ policy: VersionRetentionPolicy) {
        switch policy {
        case .keepAll:
            self.init(kind: .keepAll)
        case .keepMostRecent(let count):
            self.init(kind: .keepLast, count: count)
        case .keepWithin(let seconds):
            self.init(kind: .keepWithin, seconds: seconds)
        }
    }

    public func retentionPolicy() throws -> VersionRetentionPolicy {
        switch kind {
        case .keepAll:
            return .keepAll
        case .keepLast:
            guard let count, count > 0 else {
                throw MetaBrainDTOError.invalidRetentionCount(count)
            }
            return .keepMostRecent(count)
        case .keepWithin:
            guard let seconds, seconds >= 0, seconds.isFinite else {
                throw MetaBrainDTOError.invalidRetentionSeconds(seconds)
            }
            return .keepWithin(seconds)
        }
    }
}
