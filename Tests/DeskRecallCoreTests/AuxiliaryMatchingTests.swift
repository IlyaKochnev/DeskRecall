import Foundation
import DeskRecallCore

@MainActor extension CoreTests {
    func testAuxiliaryMatchingUsesClassAndRejectsDuplicateSavedShapes() {
        func w(_ width: Double, _ height: Double, _ layer: Int? = nil, _ subrole: String = "") -> WindowSnapshot {
            var x=WindowSnapshot(appID:"test",subrole:subrole,displayID:"mac",frame:Rect(x:0,y:0,width:width,height:height))
            x.serverLayer=layer; return x
        }
        let old=[w(900,450),w(640,472),w(640,472)]
        let now=[w(640,808,0,"AXStandardWindow"),w(900,450,19),w(640,472,8,"AXSystemDialog")]
        let result=LegacyWindowMatcher.match(saved:old,current:now)
        expectEqual(result.map(\.savedIndex),[0]); expectEqual(result.first?.currentIndex,1)
        expectEqual(result.first?.evidence,.auxiliaryFingerprint)
        let audit=WindowMatchAudit.inspect(saved:old,current:now,matches:result)
        expectEqual(audit.map(\.availability),[.matched,.ambiguous,.ambiguous])
        let smallStandard=LegacyWindowMatcher.match(saved:[w(1000,628),w(430,220),w(415,73)],current:[w(430,220,0,"AXStandardWindow"),w(415,73,3,"AXUnknown")])
        expectEqual(smallStandard.map(\.savedIndex),[1,2])
        let documents=LegacyWindowMatcher.match(saved:[w(900,700),w(1000,800)],current:[w(900,700,0,"AXStandardWindow"),w(1200,800,0,"AXStandardWindow")])
        expectTrue(documents.isEmpty)
        expectTrue(LegacyWindowMatcher.match(saved:[w(900,700,0,"AXStandardWindow")],current:[w(900,700,19,"AXUnknown")]).isEmpty)
    }
    func testAttachedPopupTracksParentAndDoesNotAnchorWholeDesktop() {
        func w(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ space: UInt64, _ role: String = "") -> WindowSnapshot {
            var w=WindowSnapshot(appID:"browser",subrole:role,displayID:"external",frame:Rect(x:x,y:y,width:width,height:height))
            w.spaces=[SpaceReference(systemID:space,displayID:"external",index:1)]; return w
        }
        let old=[w(0,0,3000,1600,1),w(99,25,2500,450,1)]
        let live=[w(100,100,3000,1600,10,"AXStandardWindow"),w(199,125,2700,380,10)]
        let matches=LegacyWindowMatcher.match(saved:old,current:live)
        expectEqual(matches.count,2); expectEqual(matches.last?.evidence,.auxiliaryAttachment)
        expectEqual(DesktopContentMatcher.match(saved:old,current:live,matches:Array(matches.suffix(1))).count,0)
        var duplicate=live; duplicate.append(live[1]); duplicate[2].runtimeToken=UUID()
        expectEqual(LegacyWindowMatcher.match(saved:old,current:duplicate).count,1)
    }
    func testMissingSubroleAllowsPersistentDocumentEvidence() {
        var old=WindowSnapshot(appID:"editor",subrole:"",documentHash:"document",displayID:"mac",frame:Rect(x:0,y:0,width:800,height:600))
        var live=old; live.runtimeToken=UUID(); live.subrole="AXStandardWindow"
        let matches=WindowMatcher.match(saved:[old],current:[live])
        expectEqual(matches.count,1); expectEqual(matches.first?.evidence,.document)
        old.subrole="AXDialog"
        expectTrue(WindowMatcher.match(saved:[old],current:[live]).isEmpty)
        let audit=WindowMatchAudit.inspect(saved:[old],current:[],matches:[])
        expectEqual(audit.first?.availability,.noCurrentWindows)
    }
}
