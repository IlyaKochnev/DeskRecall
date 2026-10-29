import AppKit
import DeskRecallCore
import DeskRecallPlatform

@MainActor enum RestoreSelfTest {
    static func run() async -> String {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskRecall/Recovery", isDirectory: true)
        let reportURL = root.appendingPathComponent("latest-restore-test.json")
        var output: [String:Any] = ["version":"0.4.2", "started":ISO8601DateFormatter().string(from:Date()),
                                   "accessibilityTrusted":PermissionService.isTrusted, "passed":false]
        let worker = WindowService()
        let restore = DesktopRestorer(windows: worker)
        var baseline: Profile?
        let topology = DisplayService.capture()
        let previousFront = NSWorkspace.shared.frontmostApplication
        do {
            guard PermissionService.isTrusted else { throw WindowServiceError.permission }
            let scan = try await worker.scan(apps: RunningApp.capture(), topology: topology)
            var profile = Profile(topology: topology, windows: scan.windows, coverage: scan.coverage)
            profile.captureScope = .systemAndAccessibility; profile.spaces = scan.spaces
            let backup = ProfileStore(directory: root.appendingPathComponent(UUID().uuidString, isDirectory:true))
            try await backup.save(profile)
            baseline = profile
            let targets = ["com.google.Chrome","com.apple.Terminal","com.apple.iCal","com.apple.ActivityMonitor"]
            var changed: [String] = []
            for app in targets {
                guard let window = profile.windows.filter({ $0.appID == app && $0.frame.width > 300 && $0.frame.height > 200 })
                    .max(by: { $0.frame.width*$0.frame.height < $1.frame.width*$1.frame.height }),
                      let source = window.spaces?.first,
                      let other = scan.spaces.first(where: { $0.displayID == source.displayID && $0.systemID != source.systemID && $0.type == 0 }) else {
                    throw WindowServiceError.unavailable
                }
                let widthDelta = app == "com.apple.Terminal" ? 11.0 : 16.0
                let frame = Rect(x:window.frame.x+8,y:window.frame.y,width:window.frame.width-widthDelta,height:window.frame.height)
                output["phase"] = "perturb: " + app
                output["targetFrame"] = ["x":frame.x,"y":frame.y,"width":frame.width,"height":frame.height]
                output["testWindowID"] = window.systemIdentity?.windowID
                do {
                    try await restore.perturb(window:window,frame:frame,spaces:[other],topology:topology)
                } catch {
                    if let actual = try? SystemWindowReader.capture(apps:RunningApp.capture()).windows.first(where: { $0.identity == window.systemIdentity }) {
                        output["actualFrame"] = ["x":actual.frame.x,"y":actual.frame.y,"width":actual.frame.width,"height":actual.frame.height]
                    }
                    throw error
                }
                changed.append(app)
            }
            output["perturbedApplications"] = changed
            output["phase"] = "restore all windows"
            let result = try await restore.restore(profile:profile,topology:topology)
            let actual = try SystemWindowReader.capture(apps: RunningApp.capture())
            var missing = 0; var wrongGeometry = 0; var wrongSpace = 0
            for saved in profile.windows {
                guard let window = actual.windows.first(where: { $0.identity == saved.systemIdentity }) else { missing += 1; continue }
                if !window.frame.isClose(to:saved.frame) { wrongGeometry += 1 }
                if Set(window.spaces.map(\.systemID)) != Set((saved.spaces ?? []).map(\.systemID)) { wrongSpace += 1 }
            }
            output["savedWindows"] = profile.windows.count; output["verified"] = result.verified
            output["constrained"] = result.constrained; output["skipped"] = result.skipped
            output["missing"] = missing; output["wrongGeometry"] = wrongGeometry; output["wrongSpace"] = wrongSpace
            output["details"] = result.details
            output["passed"] = changed.count == 4 && result.verified == profile.windows.count && missing == 0 && wrongGeometry == 0 && wrongSpace == 0
        } catch {
            output["error"] = error.localizedDescription
        }
        if let baseline {
            // A separate uncancelled recovery restores the pre-test layout even after a failed perturbation.
            do {
                let recovery = try await restore.restore(profile:baseline,topology:topology)
                output["recoveryVerified"] = recovery.verified
                output["recoveryRequested"] = recovery.requested
                output["recoveryConstrained"] = recovery.constrained
                output["recoverySkipped"] = recovery.skipped
                output["recoveryDetails"] = recovery.details
                for space in baseline.spaces ?? [] where space.active { _ = NativeWindowBridge.selectSpace(space) }
                previousFront?.activate(options: [])
            } catch { output["recoveryError"] = error.localizedDescription }
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let bytes = try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
            try bytes.write(to:reportURL,options:.atomic)
        } catch { return "Не удалось записать результат проверки: \(error.localizedDescription)" }
        return output["passed"] as? Bool == true ? "Проверка восстановления пройдена." : "Проверка восстановления не пройдена. Подробности в Recovery/latest-restore-test.json."
    }
}
