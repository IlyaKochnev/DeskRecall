import Foundation
import DeskRecallCore

@MainActor extension CoreTests {
    func testSpaceResolutionUsesMonitorAndOrdinalAfterIDsChange() throws {
        let rect = Rect(x:0,y:0,width:1440,height:900)
        let topology = Topology(displays:[DisplaySnapshot(id:"mac",name:"mac",builtIn:true,frame:rect,visibleFrame:rect),
            DisplaySnapshot(id:"external",name:"external",builtIn:false,frame:rect,visibleFrame:rect)])
        let saved = [SpaceReference(systemID:2,displayID:"external",index:2)]
        let current = [SpaceReference(systemID:2,displayID:"mac",index:2),SpaceReference(systemID:99,displayID:"external",index:2)]
        let resolved = try SpaceResolver.resolve(saved:saved,current:current,topology:topology,sameBoot:false)
        expectEqual(resolved.map(\.systemID),[99])
        let sameBoot = try SpaceResolver.resolve(saved:saved,current:current,topology:topology,sameBoot:true)
        expectEqual(sameBoot.map(\.systemID),[99])
        do {
            _ = try SpaceResolver.resolve(saved:[SpaceReference(systemID:3,displayID:"external",index:3)],current:current,topology:topology,sameBoot:false)
            recordFailure("Must not guess a different desktop when the required ordinal is missing")
        } catch { }
    }
    func testUnchangedMonitorPreservesIntentionalOffscreenGeometry() {
        let area=Rect(x:0,y:25,width:1440,height:850)
        let parked=Rect(x:-4000,y:-3000,width:200,height:100)
        expectEqual(Geometry.target(window:parked,oldArea:area,newArea:area),parked)
    }
}
