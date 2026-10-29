import AppKit
import ApplicationServices
import DeskRecallCore
import DeskRecallPlatform

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "Запуск…", action: nil, keyEquivalent: "")
    private let profileItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var saveItem: NSMenuItem!
    private var restoreItem: NSMenuItem!
    private var autoItem: NSMenuItem!
    private let windows = WindowService()
    private lazy var desktopRestorer = DesktopRestorer(windows: windows)
    private let store = ProfileStore()
    private let diagnostics = DiagnosticsLog(enabled: !CommandLine.arguments.contains("--smoke-test"))
    private var journalTimer: Timer?
    private var initialAuditDone = false
    private var automaticTrigger: DiagnosticTrigger = .startup
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pendingTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var epoch = RestoreEpoch()
    private var busy = false
    private var locked = false
    private var sleeping = false
    private var stabilizing = false
    private var autoPending = false
    private var forcePending = false
    private var stabilizationStarted: ContinuousClock.Instant?
    private var settledTopology: Topology?
    private var lastObserved: Topology?
    private var lastReport = "Пока нет операций."
    private var lastPermission = PermissionService.isTrusted
    private var permissionTimer: Timer?
    private var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "automaticRestore") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "automaticRestore") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "DeskRecall")
        statusItem.button?.toolTip = "DeskRecall — раскладки окон"
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "DeskRecall 0.4 — сохранение и восстановление", action: nil, keyEquivalent: ""))
        menu.addItem(stateItem); menu.addItem(profileItem)
        menu.addItem(.separator())
        saveItem = add("Сохранить", #selector(save), "s")
        restoreItem = add("Восстановить сейчас", #selector(restore), "r")
        autoItem = add("Восстанавливать автоматически", #selector(toggleAutomatic))
        menu.addItem(.separator())
        _ = add("Предоставить доступ…", #selector(grantAccess))
        _ = add("Последний отчёт…", #selector(showReport))
        _ = add("Проверить охват окон…", #selector(auditWindows))
        _ = add("Сводка за 48 часов…", #selector(showDiagnosticsSummary))
        _ = add("Открыть папку журнала", #selector(openDiagnostics))
        _ = add("Открыть папку профилей", #selector(openProfiles))
        let limitation = NSMenuItem(title: "Восстановление проверяет стол, монитор и геометрию", action: nil, keyEquivalent: "")
        menu.addItem(limitation)
        menu.addItem(.separator()); _ = add("Выход", #selector(quit), "q")
        statusItem.menu = menu
        settledTopology = DisplayService.capture(); lastObserved = settledTopology
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.screenChanged()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.pause(sleep: true) }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.pause(sleep: true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.resume(sleep: true) }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.resume(sleep: true) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.pause(sleep: false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.resume(sleep: false) }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.pause(sleep: false)
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.resume(sleep: false)
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPermission() }
        }
        setStatus(PermissionService.isTrusted ? "Готово. Сохраните первую раскладку." : "Сохранение доступно; для восстановления нужен доступ.")
        refreshMenu()
        journal(.applicationStarted, trigger: .startup)
        journalTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.journal(.heartbeat) }
        }
        if CommandLine.arguments.contains("--verify-restoration") {
            Task { @MainActor in
                let result = await RestoreSelfTest.run()
                self.lastReport = result
                self.setStatus("Проверка завершена. См. отчёт.")
                NSApp.terminate(nil)
            }
        } else { scheduleAutomatic(force: true, trigger: .startup) }
        // A bounded smoke launch exercises AppKit lifecycle without moving or saving windows.
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            pendingTask?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingTask?.cancel(); operationTask?.cancel(); permissionTimer?.invalidate()
        journalTimer?.invalidate()
        journal(.applicationStopped)
        diagnostics.flush()
        for (center, token) in observers { center.removeObserver(token) }
    }
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }
    private func add(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item); return item
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor @Sendable () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }
        observers.append((center, token))
    }
    private var sessionReady: Bool {
        guard !locked, !sleeping else { return false }
        if let info = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return false }
            if info["CGSSessionScreenIsLocked"] as? Bool == true { return false }
        }
        return true
    }
    private func setStatus(_ text: String) {
        stateItem.title = text; statusItem.button?.toolTip = "DeskRecall: \(text)"
    }
    private func refreshMenu() {
        let topology = DisplayService.capture()
        let trusted = PermissionService.isTrusted
        saveItem.isEnabled = sessionReady && !busy && !stabilizing && topology.isSupported
        restoreItem.isEnabled = saveItem.isEnabled && trusted
        autoItem.state = automatic ? .on : .off
        profileItem.title = "Экранов: \(topology.displays.count) · все доступные окна, включая другие столы"
        if !topology.isSupported { setStatus("Зеркалирование или неопознанные экраны не поддерживаются.") }
        if diagnostics.hasWriteFailure { setStatus("Не удалось записать журнал. Проверьте свободное место и права.") }
    }
    private func checkPermission() {
        let trusted = PermissionService.isTrusted
        if trusted != lastPermission {
            lastPermission = trusted
            journal(.permissionChanged)
            if trusted { setStatus("Доступ предоставлен."); scheduleAutomatic(force: true, trigger: .permission) }
            else { invalidate(); setStatus("Доступ отозван. Операция остановлена.") }
            refreshMenu()
        }
    }
    private func invalidate() {
        epoch.advance(); pendingTask?.cancel(); operationTask?.cancel()
    }
    private func pause(sleep: Bool) {
        if sleep { sleeping = true } else { locked = true }
        journal(.sessionPaused, trigger: sleep ? .sleep : .lock)
        invalidate(); autoPending = false; forcePending = false; stabilizationStarted = nil; stabilizing = false
        setStatus("Ожидание доступного сеанса…"); refreshMenu()
    }
    private func resume(sleep: Bool) {
        if sleep { sleeping = false } else { locked = false }
        journal(.sessionResumed, trigger: sleep ? .wake : .session)
        if sessionReady { scheduleAutomatic(force: true, trigger: sleep ? .wake : .session) }
    }
    private func screenChanged() {
        let topology = DisplayService.capture()
        guard lastObserved?.sameLayout(as: topology) != true else { return }
        lastObserved = topology
        journal(.screensChanged, topology: topology, trigger: .screens)
        scheduleAutomatic(force: true, trigger: .screens)
    }
    private func scheduleAutomatic(force: Bool, trigger: DiagnosticTrigger) {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test"), !CommandLine.arguments.contains("--verify-restoration") else { return }
        invalidate()
        automaticTrigger = trigger
        guard automatic, sessionReady else {
            stabilizing = false; forcePending = false; stabilizationStarted = nil; refreshMenu(); return
        }
        forcePending = forcePending || force
        if stabilizationStarted == nil { stabilizationStarted = .now }
        autoPending = true; stabilizing = true
        journal(.restoreScheduled, trigger: trigger)
        setStatus("Ожидание подключения экранов…"); refreshMenu()
        let generation = epoch.generation
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(1500))
                let start = self.stabilizationStarted ?? ContinuousClock.now
                var previous = DisplayService.capture()
                while true {
                    try await Task.sleep(for: .milliseconds(500))
                    guard self.epoch.accepts(generation), self.sessionReady else { return }
                    let current = DisplayService.capture()
                    if current.isSupported && current.sameLayout(as: previous) {
                        self.stabilizing = false
                        self.journal(.topologyStable, topology: current, trigger: self.automaticTrigger)
                        let changed = self.settledTopology?.sameLayout(as: current) != true
                        self.settledTopology = current
                        let shouldRestore = self.forcePending || changed
                        self.forcePending = false; self.stabilizationStarted = nil
                        if shouldRestore { self.tryAutomatic() }
                        else { self.autoPending = false; self.setStatus("Конфигурация экранов не изменилась.") }
                        self.refreshMenu(); return
                    }
                    previous = current
                    if start.duration(to: .now) > .seconds(15) {
                        self.stabilizing = false; self.autoPending = false
                        self.forcePending = false; self.stabilizationStarted = nil
                        self.journal(.stabilizationTimeout, trigger: self.automaticTrigger, reason: .unstableDisplays)
                        self.setStatus("Экраны нестабильны или режим не поддерживается. Повторите вручную.")
                        self.refreshMenu(); return
                    }
                }
            } catch { /* cancellation supersedes this topology */ }
        }
    }
    private func tryAutomatic() {
        guard autoPending, !busy, !stabilizing, automatic, sessionReady else { return }
        if !initialAuditDone {
            initialAuditDone = true
            runAudit(showResult: false, continueAutomatic: true)
            return
        }
        guard PermissionService.isTrusted else {
            journal(.automaticDeferred, trigger: automaticTrigger, reason: .permissionDenied)
            autoPending = false; return
        }
        autoPending = false
        startOperation(saving: false, trigger: automaticTrigger)
    }
    @objc private func auditWindows() { runAudit(showResult: true, continueAutomatic: false) }
    private func runAudit(showResult: Bool, continueAutomatic: Bool) {
        guard !busy, !stabilizing, sessionReady else { return }
        let topology = DisplayService.capture()
        guard topology.isSupported else { return }
        pendingTask?.cancel()
        if !continueAutomatic { autoPending = false }
        let generation = epoch.advance()
        let id = UUID()
        busy = true; refreshMenu(); setStatus("Проверка окон на всех столах…")
        journal(.operationStarted, topology: topology, id: id, operation: .audit)
        operationTask = Task { [weak self] in
            guard let self else { return }
            var counts = DiagnosticCounts(); var outcome: DiagnosticOutcome = .failed
            var reason: DiagnosticReason?
            defer {
                self.journal(.operationFinished, topology: topology, id: id, operation: .audit,
                             counts: counts, outcome: outcome, reason: reason)
                self.busy = false; self.operationTask = nil; self.refreshMenu()
                if self.autoPending { self.tryAutomatic() }
            }
            do {
                let scan = try await self.windows.scan(apps: RunningApp.capture(), topology: topology)
                try self.validate(generation, topology)
                counts.scanned = scan.windows.count; counts.excluded = scan.excluded
                counts.scanIssues = scan.issues.count; counts.coverage = scan.coverage
                self.journal(.inventoryChecked, topology: topology, id: id, operation: .audit, counts: counts)
                self.lastReport = """
                Найдено окон системным сбором: \(scan.coverage.discovered)
                Доступна геометрия: \(scan.windows.count)
                Из системного списка без AX: \(scan.coverage.systemOnly ?? 0)
                Рабочих столов прочитано: \(scan.spaces.count)
                На текущих экранах: \(scan.coverage.onScreen)
                Вне текущих экранов, включая другие столы: \(scan.coverage.offScreen)
                Свёрнутых: \(scan.coverage.minimized); полноэкранных: \(scan.coverage.fullscreen)
                Неизменяемых: \(scan.coverage.readOnly)
                Приложений опрошено: \(scan.coverage.applications)
                Ошибок чтения: \(scan.issues.count)

                Проверка не переключает столы, не перемещает окна и не меняет сохранение. Окна собираются из WindowServer независимо от Accessibility. Сохраняются существующие привязки к столам; восстановление использует сохранённые столы и проверяет результат.
                """ + (scan.issues.isEmpty ? "" : "\n\n" + scan.issues.map { "\($0.appID): \($0.reason)" }.joined(separator: "\n"))
                outcome = scan.issues.isEmpty ? .success : .partial
                self.setStatus("Проверено окон: \(scan.windows.count); ошибок: \(scan.issues.count).")
                if showResult { self.showReport() }
            } catch is CancellationError { outcome = .cancelled; reason = .contextChanged }
            catch {
                reason = self.classify(error).0
                self.lastReport = error.localizedDescription
                self.setStatus("Проверка окон не завершена. См. отчёт.")
                if showResult { self.showReport() }
            }
        }
    }
    @objc private func save() { startOperation(saving: true) }
    @objc private func restore() { startOperation(saving: false) }
    private func startOperation(saving: Bool, trigger: DiagnosticTrigger = .manual) {
        guard !busy, !stabilizing, sessionReady else { return }
        guard saving || PermissionService.isTrusted else { return }
        pendingTask?.cancel(); autoPending = false
        let generation = epoch.advance()
        let topology = DisplayService.capture()
        guard topology.isSupported else { setStatus("Эта конфигурация экранов не поддерживается."); return }
        busy = true; refreshMenu(); setStatus(saving ? "Сохранение…" : "Восстановление…")
        let operationID = UUID()
        let operation: DiagnosticOperation = saving ? .save : .restore
        journal(.operationStarted, topology: topology, id: operationID, operation: operation, trigger: trigger)
        operationTask = Task { [weak self] in
            guard let self else { return }
            let began = ContinuousClock.now
            var counts = DiagnosticCounts()
            var outcome: DiagnosticOutcome = .failed
            var reason: DiagnosticReason?
            defer {
                let duration = began.duration(to: .now).components
                let milliseconds = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
                counts.skipped = max(0, counts.requested - counts.verified - counts.constrained)
                self.journal(.operationFinished, topology: topology, id: operationID, operation: operation,
                             trigger: trigger, counts: counts, durationMS: milliseconds, outcome: outcome, reason: reason)
                self.busy = false; self.operationTask = nil; self.refreshMenu()
                if self.autoPending { self.tryAutomatic() }
            }
            do {
                let profile: Profile?
                if saving { profile = nil }
                else {
                    profile = try await self.store.load(key: topology.key)
                    guard profile != nil else {
                        try self.validate(generation, topology)
                        self.lastReport = "Для этих экранов нет сохранённого профиля. Расставьте окна и нажмите «Сохранить»."
                        outcome = .noProfile
                        self.journal(.profileMissing, topology: topology, id: operationID, operation: operation, trigger: trigger)
                        self.setStatus("Для этих экранов нет сохранения."); return
                    }
                }
                if let profile {
                    self.journal(.profileSelected, topology: topology, id: operationID, operation: operation,
                                 trigger: trigger, profile: profile)
                }
                counts.requested = profile?.windows.count ?? 0
                if let profile {
                    try await self.desktopRestorer.prepareSpaces(profile: profile, topology: topology)
                }
                try self.validate(generation, topology)
                let scan = try await self.windows.scan(apps: RunningApp.capture(), topology: topology)
                try self.validate(generation, topology)
                counts.scanned = scan.windows.count; counts.excluded = scan.excluded; counts.scanIssues = scan.issues.count; counts.coverage = scan.coverage
                self.journal(.scanCompleted, topology: topology, id: operationID, operation: operation,
                             trigger: trigger, counts: counts)
                for issue in scan.issues {
                    self.journal(.scanCompleted, topology: topology, id: operationID, operation: operation,
                                 reason: .incompleteScan, appID: issue.appID)
                }
                if saving {
                    guard !scan.windows.isEmpty else {
                        self.lastReport = "Нет доступных окон приложений. Существующий профиль оставлен без изменений."
                        outcome = .rejected; reason = .emptyScan
                        self.journal(.saveRejected, topology: topology, id: operationID, operation: operation, reason: reason)
                        self.setStatus("Нет окон для сохранения."); return
                    }
                    if !scan.issues.isEmpty {
                        self.lastReport = "Не все окна удалось прочитать. Доступно: \(scan.windows.count).\n" +
                            scan.issues.map { "\($0.appID): \($0.reason)" }.joined(separator: "\n")
                        let alert = NSAlert()
                        alert.messageText = "Часть окон недоступна"
                        alert.informativeText = "Прочитано окон: \(scan.windows.count). Ошибок чтения: \(scan.issues.count). Можно сохранить доступные окна; остальные в новый профиль не попадут. Предыдущее сохранение останется в резервной копии. Подробности — в последнем отчёте."
                        alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Сохранить доступные")
                        NSApp.activate(ignoringOtherApps: true)
                        guard alert.runModal() == .alertSecondButtonReturn else {
                            outcome = .rejected; reason = .incompleteScan
                            self.journal(.saveRejected, topology: topology, id: operationID, operation: operation, reason: reason)
                            self.setStatus("Неполный снимок. Профиль не изменён."); return
                        }
                    }
                    // Do not silently remove previously captured windows, including those on other Spaces.
                    if let old = try await self.store.load(key: topology.key) {
                        let matched = WindowMatcher.match(saved: old.windows, current: scan.windows)
                        if matched.count != old.windows.count {
                            let alert = NSAlert()
                            alert.messageText = "Заменить прежнюю раскладку?"
                            alert.informativeText = "Не найдено однозначно прежних окон: \(old.windows.count - matched.count). Они могли быть закрыты или не предоставлены приложением. Новое сохранение будет содержать окна со всех столов: \(scan.windows.count). Предыдущая версия останется в резервной копии."
                            alert.addButton(withTitle: "Отмена")
                            alert.addButton(withTitle: "Заменить сохранение")
                            NSApp.activate(ignoringOtherApps: true)
                            guard alert.runModal() == .alertSecondButtonReturn else {
                                outcome = .rejected; reason = .replacementDeclined
                                self.setStatus("Сохранение отменено. Прежний профиль не изменён."); return
                            }
                        }
                    }
                    try self.validate(generation, topology)
                    var savedProfile = Profile(topology: topology, windows: scan.windows, coverage: scan.coverage)
                    savedProfile.captureScope = .systemAndAccessibility
                    savedProfile.spaces = scan.spaces
                    try await self.store.save(savedProfile)
                    self.lastReport = "Сохранено окон: \(scan.windows.count). Исключено: \(scan.excluded).\nНа экране: \(scan.coverage.onScreen); вне активного экрана: \(scan.coverage.offScreen); свёрнутых: \(scan.coverage.minimized); полноэкранных: \(scan.coverage.fullscreen).\nОпрошено приложений: \(scan.coverage.applications). Системный сбор включает окна неактивных столов без AX. Принадлежность к столам сохранена; восстановление проверяет стол, монитор и геометрию."
                    outcome = scan.issues.isEmpty ? .success : .partial
                    if !scan.issues.isEmpty {
                        self.lastReport += "\nОшибок чтения: \(scan.issues.count).\n" + scan.issues.map { "\($0.appID): \($0.reason)" }.joined(separator: "\n")
                    }
                    self.journal(.profileSaved, topology: topology, id: operationID, operation: operation, counts: counts, profile: savedProfile)
                    self.setStatus("Сохранено окон: \(scan.windows.count); ошибок чтения: \(scan.issues.count).")
                } else if let profile {
                    let matches = WindowMatcher.match(saved: profile.windows, current: scan.windows)
                    var restored = 0; var constrained = 0
                    counts.matched = matches.count
                    var details = scan.issues.map { "\($0.appID): \($0.reason)" }
                    let unmatched = profile.windows.count - matches.count
                    let matchedIndices = Set(matches.map(\.savedIndex))
                    for index in profile.windows.indices where !matchedIndices.contains(index) {
                        let saved = profile.windows[index]
                        self.journal(.windowResult, topology: topology, id: operationID, operation: operation,
                                     outcome: .unmatched, appID: saved.appID, windowToken: saved.runtimeToken)
                    }
                    if unmatched > 0 { details.append("Не найдены однозначно или недоступны через Accessibility: \(unmatched).") }
                    for pair in matches {
                        try self.validate(generation, topology)
                        let saved = profile.windows[pair.savedIndex]
                        let current = scan.windows[pair.currentIndex]
                        guard let oldDisplay = profile.topology.displays.first(where: { $0.id == saved.displayID }),
                              let newDisplay = topology.displays.first(where: { $0.id == saved.displayID }) else { continue }
                        let target = Geometry.target(window: saved.frame, oldArea: oldDisplay.visibleFrame, newArea: newDisplay.visibleFrame)
                        do {
                            let result = try await self.desktopRestorer.restoreWindow(saved: saved, current: current, profile: profile, topology: topology)
                            try self.validate(generation, topology)
                            switch result {
                            case .restored(let actual):
                                restored += 1; counts.verified += 1
                                self.journal(.windowResult, topology: topology, id: operationID, operation: operation,
                                             outcome: .success, appID: saved.appID, windowToken: saved.runtimeToken, target: target, actual: actual)
                            case .constrained(let actual):
                                constrained += 1; counts.constrained += 1
                                self.journal(.windowResult, topology: topology, id: operationID, operation: operation,
                                             outcome: .constrained, appID: saved.appID, windowToken: saved.runtimeToken, target: target, actual: actual)
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            if !PermissionService.isTrusted { throw WindowServiceError.permission }
                            let classification = self.classify(error)
                            self.journal(.windowResult, topology: topology, id: operationID, operation: operation,
                                         outcome: .failed, reason: classification.0, appID: saved.appID,
                                         windowToken: saved.runtimeToken, target: target, errorCode: classification.1)
                            details.append("\(saved.appID): \(error.localizedDescription)")
                        }
                    }
                    try self.validate(generation, topology)
                    let skipped = profile.windows.count - restored - constrained
                    self.lastReport = "Восстановлено: \(restored). Ограничено приложением: \(constrained). Пропущено: \(skipped).\n" +
                        details.joined(separator: "\n") + "\nРезультат проверен по геометрии и принадлежности рабочим столам."
                    outcome = restored == profile.windows.count && constrained == 0 && scan.issues.isEmpty ? .success :
                        (restored + constrained > 0 ? .partial : .failed)
                    self.setStatus("Готово: \(restored); ограничения: \(constrained); пропуски: \(skipped).")
                }
            } catch is CancellationError {
                outcome = .cancelled; reason = .contextChanged
                self.lastReport = "Операция отменена из-за изменения экранов, сеанса или настроек. Уже выполненные перемещения не отменяются. Профили автоматически не перезаписываются."
                if !self.stabilizing { self.setStatus("Операция отменена.") }
            } catch {
                outcome = .failed; reason = self.classify(error).0
                self.lastReport = error.localizedDescription
                self.setStatus("Ошибка. Подробности в последнем отчёте.")
            }
        }
    }
    private func validate(_ generation: UInt64, _ topology: Topology) throws {
        try Task.checkCancellation()
        guard epoch.accepts(generation), sessionReady, DisplayService.capture().sameLayout(as: topology) else {
            throw CancellationError()
        }
    }
    @objc private func toggleAutomatic() {
        automatic.toggle(); invalidate(); autoPending = false; forcePending = false
        stabilizationStarted = nil; stabilizing = false
        journal(.automaticChanged, trigger: .setting)
        setStatus(automatic ? "Автовосстановление включено." : "Автовосстановление выключено.")
        if automatic { scheduleAutomatic(force: true, trigger: .setting) }; refreshMenu()
    }
    private func journal(_ event: DiagnosticEvent, topology: Topology? = nil, id: UUID? = nil,
                         operation: DiagnosticOperation? = nil, trigger: DiagnosticTrigger? = nil,
                         counts: DiagnosticCounts? = nil, durationMS: Int? = nil,
                         outcome: DiagnosticOutcome? = nil, reason: DiagnosticReason? = nil,
                         appID: String? = nil, windowToken: UUID? = nil, profile: Profile? = nil,
                         target: Rect? = nil, actual: Rect? = nil, errorCode: Int? = nil) {
        diagnostics.record(DiagnosticEntry(event: event, operationID: id, operation: operation, trigger: trigger,
            topology: topology ?? DisplayService.capture(), trusted: PermissionService.isTrusted,
            automatic: automatic, busy: busy, counts: counts, durationMS: durationMS, outcome: outcome,
            reason: reason, appID: appID, windowToken: windowToken, profile: profile, target: target, actual: actual, errorCode: errorCode))
    }
    private func classify(_ error: Error) -> (DiagnosticReason, Int?) {
        if error is SpaceResolutionError { return (.missingDesktop, nil) }
        if let native = error as? DesktopRestoreError {
            switch native {
            case .unsupported: return (.nativeBackendUnavailable, nil)
            case .spaceNotVerified: return (.spaceRestoreFailed, nil)
            case .geometryNotVerified: return (.windowChanged, nil)
            case .changed: return (.contextChanged, nil)
            }
        }
        if let error = error as? WindowServiceError {
            switch error {
            case .permission: return (.permissionDenied, nil)
            case .unavailable: return (.windowUnavailable, nil)
            case .changed: return (.windowChanged, nil)
            case .readOnly: return (.windowReadOnly, nil)
            case .ax(let code): return (.axFailure, Int(code))
            }
        }
        if let error = error as? ProfileStoreError {
            switch error {
            case .unsupportedSchema: return (.unknownProfileSchema, nil)
            case .invalidProfile, .topologyMismatch: return (.corruptProfile, nil)
            }
        }
        return (.ioFailure, (error as NSError).code)
    }
    @objc private func openDiagnostics() {
        diagnostics.flush()
        let directory = diagnostics.directory
        if FileManager.default.fileExists(atPath: directory.path) { NSWorkspace.shared.open(directory) }
        else {
            let alert = NSAlert(); alert.messageText = "Журнал пока недоступен"
            alert.informativeText = "Проверьте свободное место и права на папку журналов пользователя."
            alert.runModal()
        }
    }
    @objc private func showDiagnosticsSummary() {
        Task { [weak self] in
            guard let self else { return }
            let history = await self.diagnostics.history(since: Date().addingTimeInterval(-48 * 3600))
            let summary = DiagnosticsSummary(entries: history.entries)
            let alert = NSAlert(); alert.messageText = "DeskRecall — последние 48 часов"
            let average = summary.completedRestores > 0 ? summary.durationMS / summary.completedRestores : 0
            alert.informativeText = """
            Сохранений: \(summary.saved)
            Восстановления полностью: \(summary.restored)
            Частично: \(summary.partial); ошибки: \(summary.failed)
            Отменено: \(summary.cancelled); нет профиля: \(summary.noProfile)
            Окна: подтверждено \(summary.verifiedWindows) из \(summary.requestedWindows)
            Ограничено приложением: \(summary.constrainedWindows); пропущено: \(summary.skippedWindows)
            Среднее время завершённых попыток: \(average) мс
            Отложено без доступа: \(summary.permissionDeferrals)
            Незавершённых операций: \(summary.incompleteOperations)
            Отметок работы приложения: \(summary.heartbeatCount)
            Непрочитанных строк журнала: \(history.unreadableLines)

            Координаты проверяются сразу после восстановления. Последующие изменения окон не отслеживаются. Успешный результат включает проверку рабочих столов.
            """
            alert.addButton(withTitle: "Закрыть"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    @objc private func grantAccess() {
        PermissionService.request()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func showReport() {
        let alert = NSAlert(); alert.messageText = "DeskRecall — последний отчёт"
        alert.informativeText = lastReport
        alert.addButton(withTitle: "Закрыть"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc private func openProfiles() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskRecall/Profiles", isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else {
            let alert = NSAlert(); alert.messageText = "Сохранений пока нет"
            alert.informativeText = "Папка профилей появится после первого сохранения."; alert.runModal()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
