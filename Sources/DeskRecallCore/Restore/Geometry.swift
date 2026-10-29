import Foundation

public enum Geometry {
    // AppKit uses a bottom-left origin; AX and CoreGraphics window bounds use top-left.
    public static func fromAppKit(_ rect: Rect, primaryTop: Double) -> Rect {
        Rect(x: rect.x, y: primaryTop - rect.y - rect.height, width: rect.width, height: rect.height)
    }
    public static func display(for window: Rect, in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        guard window.isValid else { return nil }
        if let best = displays.max(by: { window.intersectionArea($0.frame) < window.intersectionArea($1.frame) }),
           window.intersectionArea(best.frame) > 0 { return best }
        // Preserve windows outside display bounds rather than dropping them from the snapshot.
        let x = window.x + window.width / 2; let y = window.y + window.height / 2
        return displays.min { a, b in
            let da = pow(x - (a.frame.x + a.frame.width / 2), 2) + pow(y - (a.frame.y + a.frame.height / 2), 2)
            let db = pow(x - (b.frame.x + b.frame.width / 2), 2) + pow(y - (b.frame.y + b.frame.height / 2), 2)
            return da < db
        }
    }
    public static func target(window: Rect, oldArea: Rect, newArea: Rect) -> Rect {
        guard window.isValid, oldArea.isValid, newArea.isValid else { return newArea }
        let proposed: Rect
        if oldArea == newArea {
            return window // Preserve intentional off-screen auxiliary windows on an unchanged layout.
        } else {
            proposed = Rect(x: newArea.x + (window.x - oldArea.x) / oldArea.width * newArea.width,
                            y: newArea.y + (window.y - oldArea.y) / oldArea.height * newArea.height,
                            width: window.width / oldArea.width * newArea.width,
                            height: window.height / oldArea.height * newArea.height)
        }
        let width = min(newArea.width, max(1, proposed.width))
        let height = min(newArea.height, max(1, proposed.height))
        return Rect(x: max(newArea.x, min(proposed.x, newArea.x + newArea.width - width)),
                    y: max(newArea.y, min(proposed.y, newArea.y + newArea.height - height)),
                    width: width, height: height)
    }
}
