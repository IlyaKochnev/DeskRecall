import AppKit
import CryptoKit
import DeskRecallCore
import DeskRecallPlatform

@MainActor enum SavedRestoreTest {
    static func run() async -> String {
        let base = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("DeskRecall")
        let root = base.appendingPathComponent("Recovery/reboot-" + UUID().uuidString)
        let profiles = base.appendingPathComponent("Profiles")
        var report: [String:Any] = ["version":"0.5.0","started":ISO8601DateFormatter().string(from:Date()),"trusted":PermissionService.isTrusted,"passed":false]
        let topology = DisplayService.capture()
        let worker = WindowService(); let restorer = DesktopRestorer(windows:worker)
        var baseline: Profile?
        var original: [String:Data] = [:]
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let copies = root.appendingPathComponent("Profiles")
            try FileManager.default.createDirectory(at:copies,withIntermediateDirectories:true)
            for file in try FileManager.default.contentsOfDirectory(at:profiles,includingPropertiesForKeys:nil) where !file.hasDirectoryPath {
                let data = try Data(contentsOf:file); original[file.lastPathComponent] = data
                try data.write(to:copies.appendingPathComponent(file.lastPathComponent),options:.atomic)
            }
            guard PermissionService.isTrusted else { throw WindowServiceError.permission }
            let scan = try await worker.scanForPersistence(apps:RunningApp.capture(),topology:topology)
            var backup = Profile(topology:topology,windows:scan.windows,coverage:scan.coverage)
            backup.spaces=scan.spaces; baseline=backup
            try await ProfileStore(directory:root.appendingPathComponent("Baseline")).save(backup)
            guard let profile = try await ProfileStore().load(key:topology.key) else { throw WindowServiceError.unavailable }
            let matches=LegacyWindowMatcher.match(saved:profile.windows,current:scan.windows)
            let content=DesktopContentMatcher.match(saved:profile.windows,current:scan.windows,matches:matches)
            report["requested"]=profile.windows.count; report["matched"]=matches.count
            report["unmatched"]=profile.windows.count-matches.count
            report["contentMappedDesktops"]=content.count
            report["beforeDesktopCounts"]=topology.displays.map { d in scan.spaces.filter { $0.displayID == d.id }.count }
            let result=try await restorer.restore(profile:profile,topology:topology)
            let actual=try SystemWindowReader.capture(apps:RunningApp.capture())
            var verified=0; var issues: [String]=[]
            for match in matches {
                let saved=profile.windows[match.savedIndex]; let current=scan.windows[match.currentIndex]
                guard let identity=current.systemIdentity,
                      let live=actual.windows.first(where: { $0.identity == identity }),
                      let old=profile.topology.displays.first(where: { $0.id == saved.displayID }),
                      let new=topology.displays.first(where: { $0.id == saved.displayID }) else { issues.append(saved.appID+": missing"); continue }
                let target=Geometry.target(window:saved.frame,oldDisplay:old,newDisplay:new)
                let desired=try SpaceResolver.resolve(saved:saved.spaces ?? [],current:actual.spaces,topology:topology,sameBoot:false)
                if live.frame.isClose(to:target) && Set(live.spaces.map(\.systemID)) == Set(desired.map(\.systemID)) { verified += 1 }
                else { issues.append(saved.appID+": geometry or desktop mismatch") }
            }
            report["verified"]=verified; report["restorerVerified"]=result.verified
            report["constrained"]=result.constrained; report["skipped"]=result.skipped
            report["details"]=result.details; report["independentIssues"]=issues
            report["afterDesktopCounts"]=topology.displays.map { d in actual.spaces.filter { $0.displayID == d.id }.count }
            report["matchedApplications"]=matches.map { profile.windows[$0.savedIndex].appID }
            report["matchedWindowsPassed"]=matches.count > 0 && verified == matches.count && issues.isEmpty
            report["passed"]=verified == profile.windows.count && issues.isEmpty
            report["verifiedContentDesktopMappings"]=content.filter { old,id in
                guard let desired=profile.spaces?.first(where: { $0.systemID == old }) else { return false }
                return actual.spaces.contains { $0.systemID == id && $0.displayID == desired.displayID && $0.index == desired.index }
            }.count
        } catch {
            report["error"]=error.localizedDescription
            if let baseline {
                let recovery=try? await restorer.restore(profile:baseline,topology:topology)
                report["recoveryVerified"]=recovery?.verified
            }
        }
        report["profilesUnchanged"]=original.allSatisfy { name,data in (try? Data(contentsOf:profiles.appendingPathComponent(name))) == data }
        do {
            let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:root.appendingPathComponent("report.json"),options:.atomic)
            try data.write(to:base.appendingPathComponent("Recovery/latest-reboot-test.json"),options:.atomic)
        } catch { return error.localizedDescription }
        return "Проверка завершена. См. Recovery/latest-reboot-test.json."
    }
}
