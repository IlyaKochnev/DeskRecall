import Foundation

public struct WindowMatchAudit: Codable, Sendable {
    public enum Availability: String, Codable, Sendable {
        case matched, noCurrentWindows, ambiguous, notIdentified
    }
    public var savedIndex: Int
    public var appID: String
    public var availability: Availability
    public var currentIndices: [Int]
    public var evidence: WindowMatchEvidence?
    public static func inspect(saved: [WindowSnapshot], current: [WindowSnapshot], matches: [WindowMatch]) -> [WindowMatchAudit] {
        saved.indices.map { i in
            let w=saved[i]
            if let match=matches.first(where: { $0.savedIndex == i }) {
                return Self(savedIndex:i,appID:w.appID,availability:.matched,currentIndices:[match.currentIndex],evidence:match.evidence)
            }
            let peers=current.indices.filter { current[$0].appID == w.appID }
            let candidates=peers.filter { j in
                let c=current[j]
                return w.role == c.role && (w.subrole.isEmpty || c.subrole.isEmpty || w.subrole == c.subrole) &&
                    abs(w.frame.width-c.frame.width) <= 1 && abs(w.frame.height-c.frame.height) <= 1
            }
            // A live shape is evidence of an unresolved candidate, not proof that the saved window closed.
            return Self(savedIndex:i,appID:w.appID,availability:peers.isEmpty ? .noCurrentWindows : (candidates.isEmpty ? .notIdentified : .ambiguous),currentIndices:candidates,evidence:nil)
        }
    }
}
