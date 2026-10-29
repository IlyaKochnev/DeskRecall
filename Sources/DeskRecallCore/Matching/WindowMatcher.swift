import Foundation

public struct WindowMatch: Sendable, Equatable {
    public var savedIndex: Int
    public var currentIndex: Int
}

public enum WindowMatcher {
    public static func match(saved: [WindowSnapshot], current: [WindowSnapshot]) -> [WindowMatch] {
        var remainingSaved = Set(saved.indices)
        var remainingCurrent = Set(current.indices)
        var matches: [WindowMatch] = []
        for tier in 0..<5 {
            var proposals: [Int: [Int]] = [:]
            for s in remainingSaved {
                let a = saved[s]
                proposals[s] = remainingCurrent.filter { c in
                    let b = current[c]
                    guard a.appID == b.appID else { return false }
                    if tier == 0 { return a.systemIdentity != nil && a.systemIdentity == b.systemIdentity }
                    guard a.role == b.role, a.subrole == b.subrole else { return false }
                    switch tier {
                    case 1: return a.runtimeToken == b.runtimeToken
                    case 2: return equalNonempty(a.documentHash, b.documentHash)
                    case 3: return equalNonempty(a.identifierHash, b.identifierHash)
                    default: return equalNonempty(a.titleHash, b.titleHash)
                    }
                }
            }
            // Both sides must be unique at this evidence tier. Never choose an arbitrary duplicate.
            for s in remainingSaved.sorted() {
                guard let candidates = proposals[s], candidates.count == 1, let c = candidates.first,
                      proposals.values.filter({ $0.contains(c) }).count == 1 else { continue }
                matches.append(WindowMatch(savedIndex: s, currentIndex: c))
                remainingSaved.remove(s); remainingCurrent.remove(c)
            }
        }
        return matches.sorted { $0.savedIndex < $1.savedIndex }
    }
    private static func equalNonempty(_ a: String?, _ b: String?) -> Bool {
        guard let a, !a.isEmpty, let b else { return false }; return a == b
    }
}
