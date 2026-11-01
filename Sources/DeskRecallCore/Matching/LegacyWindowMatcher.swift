import Foundation

/// Explicit compatibility path for old server-only profiles. Never resolves duplicate peers by order.
public enum LegacyWindowMatcher {
    public static func match(saved: [WindowSnapshot], current: [WindowSnapshot], includeAuxiliary: Bool = true) -> [WindowMatch] {
        var result = WindowMatcher.match(saved: saved, current: current)
        var usedSaved = Set(result.map(\.savedIndex)); var usedCurrent = Set(result.map(\.currentIndex))
        for app in Set(saved.map(\.appID)).sorted() {
            let a = saved.indices.filter { saved[$0].appID == app }
            let b = current.indices.filter { current[$0].appID == app }
            func append(_ s: Int, _ c: Int, _ evidence: WindowMatchEvidence) {
                guard !usedSaved.contains(s), !usedCurrent.contains(c) else { return }
                result.append(WindowMatch(savedIndex:s,currentIndex:c,evidence:evidence)); usedSaved.insert(s); usedCurrent.insert(c)
            }
            // One window on each side is an explicit application-level identity fallback.
            if a.count == 1, b.count == 1 {
                let old=saved[a[0]]; let now=current[b[0]]
                let subroleCompatible=old.subrole.isEmpty || now.subrole.isEmpty || old.subrole == now.subrole
                let layerCompatible=old.serverLayer == nil || now.serverLayer == nil || old.serverLayer == now.serverLayer
                if old.role == now.role && subroleCompatible && layerCompatible && !(old.subrole == "AXStandardWindow" && (now.serverLayer ?? 0) > 0) {
                    append(a[0],b[0],.applicationSingleton)
                }
                continue
            }
            // Legacy captures included helper surfaces. A single dominant normal window can survive
            // monitor-induced resizing. Do not infer a primary among comparable document windows.
            func primary(_ indices: [Int], _ list: [WindowSnapshot]) -> Int? {
                let sorted = indices.sorted { list[$0].frame.width*list[$0].frame.height > list[$1].frame.width*list[$1].frame.height }
                guard let first = sorted.first, list[first].role == "AXWindow", (list[first].serverLayer ?? 0) == 0,
                      list[first].subrole.isEmpty || list[first].subrole == "AXStandardWindow",
                      list[first].frame.width >= 500, list[first].frame.height >= 300 else { return nil }
                if sorted.count > 1 {
                    let next = list[sorted[1]].frame
                    guard list[first].frame.width*list[first].frame.height > 4*next.width*next.height else { return nil }
                }
                return first
            }
            if let s = primary(a,saved), let c = primary(b,current) { append(s,c,.dominantWindow) }
            guard includeAuxiliary else { continue }
            func nonstandard(_ w: WindowSnapshot) -> Bool {
                w.role == "AXSheet" || (!w.subrole.isEmpty && w.subrole != "AXStandardWindow") ||
                    (w.serverLayer ?? 0) > 0 || (w.frame.width <= 500 && w.frame.height <= 250)
            }
            func compatible(_ x: WindowSnapshot, _ y: WindowSnapshot) -> Bool {
                x.role == y.role && (x.subrole.isEmpty || y.subrole.isEmpty || x.subrole == y.subrole) &&
                    (x.serverLayer == nil || y.serverLayer == nil || x.serverLayer == y.serverLayer)
            }
            // Inspect all peers, including consumed ones: removing a primary must not make a
            // previously ambiguous auxiliary appear unique. Old profiles lack the layer; the
            // current nonstandard class supplies a separate discriminator beyond dimensions.
            var proposals: [Int:[Int]] = [:]
            for i in a where !usedSaved.contains(i) && saved[i].subrole != "AXStandardWindow" {
                proposals[i] = b.filter { j in
                    let x=saved[i]; let y=current[j]
                    return compatible(x,y) && nonstandard(y) && (y.subrole != "AXStandardWindow" || (y.frame.width <= 500 && y.frame.height <= 250)) &&
                        abs(x.frame.width-y.frame.width) <= 1 && abs(x.frame.height-y.frame.height) <= 1
                }
            }
            for i in a where !usedSaved.contains(i) {
                guard let candidates=proposals[i], candidates.count == 1, let j=candidates.first,
                      proposals.values.filter({ $0.contains(j) }).count == 1 else { continue }
                append(i,j,.auxiliaryFingerprint)
            }
            // Wide application-owned popups may change dimensions with content. Match their
            // attachment to an already identified main window, never just their screen position.
            let parents=result.filter { a.contains($0.savedIndex) && ![WindowMatchEvidence.auxiliaryFingerprint,.auxiliaryAttachment].contains($0.evidence) }
            var attached: [Int:[Int]] = [:]
            for i in a where !usedSaved.contains(i) && saved[i].subrole != "AXStandardWindow" {
                attached[i]=b.filter { j in
                    guard !usedCurrent.contains(j), current[j].subrole != "AXStandardWindow", compatible(saved[i],current[j]) else { return false }
                    return parents.contains { parent in
                        let old=saved[parent.savedIndex]; let now=current[parent.currentIndex]
                        let x=saved[i].frame; let y=current[j].frame
                        guard x.width >= old.frame.width/2, y.width >= now.frame.width/2,
                              x.height < old.frame.height/3, y.height < now.frame.height/3,
                              Set((saved[i].spaces ?? []).map(\.systemID)) == Set((old.spaces ?? []).map(\.systemID)),
                              Set((current[j].spaces ?? []).map(\.systemID)) == Set((now.spaces ?? []).map(\.systemID)) else { return false }
                        return abs((x.x-old.frame.x)-(y.x-now.frame.x)) <= 2 && abs((x.y-old.frame.y)-(y.y-now.frame.y)) <= 2
                    }
                }
            }
            for i in a where !usedSaved.contains(i) {
                guard let candidates=attached[i], candidates.count == 1, let j=candidates.first,
                      attached.values.filter({ $0.contains(j) }).count == 1 else { continue }
                append(i,j,.auxiliaryAttachment)
            }
        }
        return result.sorted { $0.savedIndex < $1.savedIndex }
    }
}
