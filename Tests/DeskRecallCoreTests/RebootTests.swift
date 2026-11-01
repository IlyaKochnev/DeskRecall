import Foundation
import DeskRecallCore

@MainActor extension CoreTests {
    func testScreenCoveringSurfaceIgnoresDockInsets() {
        let frame=Rect(x:0,y:0,width:1512,height:982)
        let old=DisplaySnapshot(id:"mac",name:"mac",builtIn:true,frame:frame,visibleFrame:Rect(x:59,y:33,width:1453,height:949))
        let new=DisplaySnapshot(id:"mac",name:"mac",builtIn:true,frame:frame,visibleFrame:Rect(x:56,y:33,width:1456,height:949))
        expectEqual(Geometry.target(window:frame,oldDisplay:old,newDisplay:new),frame)
    }
    func testLegacyMatchingSurvivesRebootWithoutGuessingPeers() {
        func w(_ app: String, _ width: Double, _ height: Double) -> WindowSnapshot {
            WindowSnapshot(appID:app,subrole:"",displayID:"mac",frame:Rect(x:0,y:0,width:width,height:height))
        }
        let saved = [w("terminal",1400,900),w("chrome",3000,1600),w("chrome",400,80),w("editor",900,700),w("editor",1000,800)]
        let live = [w("terminal",1300,900),w("chrome",1450,900),w("chrome",400,80),w("editor",1100,700),w("editor",1200,800)]
        let result = LegacyWindowMatcher.match(saved:saved,current:live)
        expectEqual(result.map(\.savedIndex),[0,1,2]); expectEqual(result.map(\.currentIndex),[0,1,2])
        expectEqual(result.last?.evidence,.auxiliaryFingerprint)
        expectEqual(WindowMatcher.match(saved:saved,current:live).count,0)
        expectTrue(LegacyWindowMatcher.match(saved:[w("app",1000,800)],current:[w("app",1000,800),w("app",1000,800)]).isEmpty)
    }
    func testContentMatchingRejectsMergedAndTiedDesktops() {
        func w(_ space: UInt64) -> WindowSnapshot {
            var x = WindowSnapshot(appID:"app",displayID:"mac",frame:Rect(x:0,y:0,width:1000,height:800))
            x.spaces=[SpaceReference(systemID:space,displayID:"mac",index:1)]; return x
        }
        let pairs=(0..<4).map { WindowMatch(savedIndex:$0,currentIndex:$0) }
        let map=DesktopContentMatcher.match(saved:[w(1),w(2),w(3),w(3)],current:[w(10),w(10),w(30),w(30)],matches:pairs)
        expectEqual(map,[3:30]); expectTrue(map[1] == nil); expectTrue(map[2] == nil)
        expectTrue(DesktopContentMatcher.match(saved:[w(1),w(1)],current:[w(10),w(11)],matches:Array(pairs.prefix(2))).isEmpty)
    }
}
