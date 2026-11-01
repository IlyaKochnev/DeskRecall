import Foundation

/// Explicit compatibility path for old server-only profiles. Never resolves duplicate peers by order.
public enum LegacyWindowMatcher {
    public static func match(saved: [WindowSnapshot], current: [WindowSnapshot]) -> [WindowMatch] {
        var result = WindowMatcher.match(saved: saved, current: current)
        var usedSaved = Set(result.map(\.savedIndex)); var usedCurrent = Set(result.map(\.currentIndex))
        for app in Set(saved.map(\.appID)).sorted() {
            let a = saved.indices.filter { saved[$0].appID == app }
            let b = current.indices.filter { current[$0].appID == app }
            func append(_ s: Int, _ c: Int) {
                guard !usedSaved.contains(s), !usedCurrent.contains(c) else { return }
                result.append(WindowMatch(savedIndex:s,currentIndex:c)); usedSaved.insert(s); usedCurrent.insert(c)
            }
            // One window on each side is an explicit application-level identity fallback.
            if a.count == 1, b.count == 1 { append(a[0],b[0]); continue }
            // Legacy captures included helper surfaces. A single dominant normal window can survive
            // monitor-induced resizing. Do not infer a primary among comparable document windows.
            func primary(_ indices: [Int], _ list: [WindowSnapshot]) -> Int? {
                let sorted = indices.sorted { list[$0].frame.width*list[$0].frame.height > list[$1].frame.width*list[$1].frame.height }
                guard let first = sorted.first, list[first].role == "AXWindow",
                      list[first].subrole.isEmpty || list[first].subrole == "AXStandardWindow",
                      list[first].frame.width >= 500, list[first].frame.height >= 300 else { return nil }
                if sorted.count > 1 {
                    let next = list[sorted[1]].frame
                    guard list[first].frame.width*list[first].frame.height > 4*next.width*next.height else { return nil }
                }
                return first
            }
            if let s = primary(a,saved), let c = primary(b,current) { append(s,c) }
            // Auxiliary surfaces are deliberately not identified from size alone.
        }
        return result.sorted { $0.savedIndex < $1.savedIndex }
    }
}
