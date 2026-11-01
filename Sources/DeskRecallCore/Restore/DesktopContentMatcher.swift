import Foundation

public enum DesktopContentMatcher {
    /// Only pure groups: a desktop containing anchors for multiple saved desktops is a merged group.
    public static func match(saved: [WindowSnapshot], current: [WindowSnapshot], matches: [WindowMatch]) -> [UInt64: UInt64] {
        var votes: [UInt64: [UInt64:Int]] = [:]
        var owners: [UInt64:Set<UInt64>] = [:]
        for pair in matches {
            guard pair.evidence != .auxiliaryFingerprint && pair.evidence != .auxiliaryAttachment else { continue }
            guard let a = saved[pair.savedIndex].spaces, a.count == 1,
                  let b = current[pair.currentIndex].spaces, b.count == 1,
                  a[0].type == 0, b[0].type == 0 else { continue }
            votes[a[0].systemID,default:[:]][b[0].systemID,default:0] += 1
            owners[b[0].systemID,default:[]].insert(a[0].systemID)
        }
        var output: [UInt64:UInt64] = [:]
        for (savedID, candidates) in votes {
            let pure = candidates.filter { owners[$0.key] == Set([savedID]) }
            guard let maximum = pure.values.max(), pure.values.filter({ $0 == maximum }).count == 1,
                  let winner = pure.first(where: { $0.value == maximum }) else { continue }
            output[savedID] = winner.key
        }
        return output
    }
}
