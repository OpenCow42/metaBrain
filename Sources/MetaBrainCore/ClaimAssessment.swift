import Crypto
import Foundation

public enum ClaimState: String, Codable, Sendable {
    case accepted, provisional, contested, unsupported, deprecated
}

public enum ClaimRelation: String, Codable, Sendable {
    case supports, contradicts
}

public enum ClaimSourceStatus: String, Codable, Sendable {
    case active, superseded, disputed
}

/// Assessment of a source. A group identifies its original reporting or authorship.
public struct ClaimSourceProfile: Codable, Equatable, Sendable {
    public let status: ClaimSourceStatus
    public let synthetic: Bool
    public let independenceGroup: String
    public let freshUntil: Date

    public init(status: ClaimSourceStatus, synthetic: Bool, independenceGroup: String, freshUntil: Date) {
        self.status = status
        self.synthetic = synthetic
        self.independenceGroup = independenceGroup
        // The public JSON transport represents UTC timestamps to the second.
        self.freshUntil = Date(timeIntervalSince1970: freshUntil.timeIntervalSince1970.rounded(.down))
    }

    public func validate() throws {
        guard !independenceGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              freshUntil.timeIntervalSinceReferenceDate.isFinite else {
            throw ProjectOperationError.invalid("A source assessment requires an independence group and freshness deadline.")
        }
    }
}

public struct ClaimEvidence: Codable, Hashable, Sendable {
    public let relation: ClaimRelation
    public let ref: EvidenceReference

    public init(relation: ClaimRelation, ref: EvidenceReference) {
        self.relation = relation
        self.ref = ref
    }

    /// Stable navigation target even after renames and moves.
    public var sourceID: DocumentID { ref.documentID }
}

/// A claim ID is stable across versions of its owning document.
public struct ProjectClaim: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let state: ClaimState
    public let highRisk: Bool
    public let evidence: [ClaimEvidence]

    public init(id: UUID, text: String, state: ClaimState, highRisk: Bool = false, evidence: [ClaimEvidence]) {
        self.id = id
        self.text = text
        self.state = state
        self.highRisk = highRisk
        self.evidence = evidence
    }
}

public struct ClaimIssue: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case missing, invalid, stale, superseded, disputed, ineligible, insufficient, contradiction
    }

    public let kind: Kind
    public let message: String
    public let ref: EvidenceReference?
    public let isWriteError: Bool
}

public enum ClaimAssessment {
    /// Evaluates retained quotations and current source standing without modifying the claim.
    public static func evaluate(
        _ claim: ProjectClaim,
        asOf date: Date,
        project: DocumentPath? = nil,
        source: (EvidenceReference) async throws -> (retained: StoredDocument?, current: StoredDocument?)
    ) async throws -> [ClaimIssue] {
        var findings: [ClaimIssue] = []
        func report(_ kind: ClaimIssue.Kind, _ message: String, ref: EvidenceReference? = nil) {
            let blocksWrite = kind == .invalid || kind == .missing || kind == .insufficient || kind == .contradiction
            findings.append(ClaimIssue(kind: kind, message: message, ref: ref, isWriteError: blocksWrite))
        }

        if claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report(.invalid, "A claim needs a statement.")
        }
        var seen: Set<ClaimEvidence> = []
        var supportingGroups: Set<String> = []
        var supportingOriginals: Set<String> = []
        for evidence in claim.evidence {
            let ref = evidence.ref
            guard seen.insert(evidence).inserted else {
                report(.invalid, "The same evidence relationship appears twice.", ref: ref)
                continue
            }
            let pair = try await source(ref)
            if let project,
               let outside = [pair.current, pair.retained].compactMap({ $0 }).first(where: {
                   $0.path != project && !$0.path.rawValue.utf8.starts(with: (project.rawValue + "/").utf8)
               }) {
                report(.invalid, "Source \(outside.path) is outside reviewed project \(project).", ref: ref)
                continue
            }
            guard let pinned = pair.retained, let current = pair.current else {
                report(.missing, "The source or its cited revision is unavailable.", ref: ref)
                continue
            }
            let text: String
            do {
                text = try ref.exactText(in: pinned)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    report(.invalid, "The cited passage is empty.", ref: ref)
                    continue
                }
            } catch {
                report(.invalid, String(describing: error), ref: ref)
                continue
            }
            let live = EvidenceReference(document: current, location: ref.location)
            guard current.id == ref.documentID,
                  let liveText = try? live.exactText(in: current), text.utf8.elementsEqual(liveText.utf8) else {
                report(.stale, "The current source has changed at the cited passage.", ref: ref)
                continue
            }
            guard let profile = current.sourceProfile else {
                report(.ineligible, "The source has no recorded assessment.", ref: ref)
                continue
            }
            switch profile.status {
            case .superseded:
                report(.superseded, "The source has been superseded.", ref: ref)
                continue
            case .disputed:
                report(.disputed, "The source is disputed.", ref: ref)
                continue
            case .active:
                break
            }
            guard !profile.synthetic else {
                report(.ineligible, "The source is marked synthetic.", ref: ref)
                continue
            }
            guard profile.freshUntil > date else {
                report(.stale, "The source freshness deadline has passed.", ref: ref)
                continue
            }
            if evidence.relation == .supports {
                let provenance = pinned.sourceProfile ?? profile
                let group = provenance.independenceGroup.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let original = pinned.sourceCapture?.blob.sha256 ?? SHA256.hash(data: Data(pinned.body.utf8)).hexString
                supportingGroups.insert(group)
                supportingOriginals.insert(original)
            } else if claim.state == .accepted {
                report(.contradiction, "Active evidence contradicts the accepted claim.", ref: ref)
            }
        }
        if claim.state == .accepted {
            if supportingGroups.isEmpty {
                report(.insufficient, "An accepted claim requires eligible supporting evidence.")
            } else if claim.highRisk && (supportingGroups.count < 2 || supportingOriginals.count < 2) {
                report(.insufficient, "A high-risk claim requires two independent supporting sources.")
            }
        }
        return findings
    }
}
