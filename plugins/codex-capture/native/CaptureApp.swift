import AppKit
import ApplicationServices
import Carbon
import Foundation

private let appID = "com.yiminlab.codex-capture"
private let helperVersion = "0.4.2"
private let dataDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_CAPTURE_DATA"] ?? (NSHomeDirectory() + "/.local/state/codex-capture"), isDirectory: true)
private let statusURL = dataDirectory.appendingPathComponent("hotkey-status.json")
private let launcherURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_CAPTURE_LAUNCHER"] ?? (NSHomeDirectory() + "/.local/bin/codex-capture"))
private let axPreference = "includeAccessibilityContext"

private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

private struct ScreenCapturePermissionState {
    private(set) var allowed = false
    private(set) var requested = false
    private(set) var checkedAt: String?

    mutating func refresh(using check: () -> Bool) {
        allowed = check()
        checkedAt = timestamp()
    }

    mutating func allowsCapture(check: () -> Bool, request: () -> Bool) -> Bool {
        refresh(using: check)
        if allowed { return true }
        guard !requested else { return false }
        // Persist before entering the system permission UI, including denial.
        requested = true
        allowed = request()
        return allowed
    }
}

private func submissionArguments(image: String, text: String, context: String) -> [String] {
    // Keep the user's text byte-for-byte, including leading dashes and whitespace.
    ["submit", "--image", image, "--text=" + text, "--context-file", context]
}

private func writeJSON(_ value: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func safeURL(_ value: String) -> String? {
    guard var url = URLComponents(string: value), let scheme = url.scheme,
          ["http", "https", "file"].contains(scheme.lowercased()) else { return nil }
    url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
    return url.string.map { String($0.prefix(500)) }
}

private func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}

private func axString(_ element: AXUIElement, _ name: String) -> String? {
    let value = axValue(element, name) as? String
    guard let value, !value.isEmpty else { return nil }
    return String(value.prefix(500))
}

/// Reads one focused window only, when the user has enabled this feature and
/// macOS has already granted access. No API here requests or grants permission.
private func foregroundContext(_ app: NSRunningApplication?, includeAX: Bool) -> [String: Any] {
    var context: [String: Any] = ["capturedAt": timestamp()]
    guard let app else {
        context["accessibility"] = ["status": "no_foreground_app", "nodes": []] as [String: Any]
        return context
    }
    context["app"] = ["name": app.localizedName ?? "", "bundleId": app.bundleIdentifier ?? "", "pid": Int(app.processIdentifier)]
    guard includeAX else {
        context["accessibility"] = ["status": "disabled", "nodes": []] as [String: Any]
        return context
    }
    guard AXIsProcessTrusted() else {
        context["accessibility"] = ["status": "permission_required", "nodes": []] as [String: Any]
        return context
    }
    let started = Date()
    let deadline = started.addingTimeInterval(0.9)
    // Global timeout is scoped to this process, not the inspected application.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.05)
    let application = AXUIElementCreateApplication(app.processIdentifier)
    guard let rawWindow = axValue(application, kAXFocusedWindowAttribute as String),
          CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
        context["accessibility"] = ["status": "unavailable", "nodes": [], "reason": "No accessible focused window"] as [String: Any]
        return context
    }
    let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
    var windowInfo: [String: String] = [:]
    if let title = axString(window, kAXTitleAttribute as String) { windowInfo["title"] = title }
    if let document = axString(window, kAXDocumentAttribute as String), let url = safeURL(document) { windowInfo["url"] = url }
    context["window"] = windowInfo

    struct Pending { let element: AXUIElement; let depth: Int; let parent: Int? }
    var pending = [Pending(element: window, depth: 0, parent: nil)]
    var cursor = 0
    var visited = Set<CFHashCode>()
    var nodes = [[String: Any]]()
    var textCount = 0
    var truncated = false
    while cursor < pending.count {
        guard nodes.count < 160, textCount < 14_000, Date() < deadline else { truncated = true; break }
        let entry = pending[cursor]; cursor += 1
        let element = entry.element
        guard visited.insert(CFHash(element)).inserted else { continue }
        guard let role = axString(element, kAXRoleAttribute as String) else { continue }
        let subrole = axString(element, kAXSubroleAttribute as String) ?? ""
        let secure = subrole.localizedCaseInsensitiveContains("secure") || role.localizedCaseInsensitiveContains("secure")
        var node: [String: Any] = ["role": role, "depth": entry.depth]
        if !subrole.isEmpty { node["subrole"] = subrole }
        if let parent = entry.parent { node["parent"] = parent }
        let index = nodes.count
        if !secure {
            for (attribute, key) in [(kAXTitleAttribute as String, "title"), (kAXDescriptionAttribute as String, "description")] {
                guard Date() < deadline else { truncated = true; break }
                if let text = axString(element, attribute) { node[key] = text; textCount += text.count }
            }
            // Never read values of editable fields, search boxes, passwords,
            // combo boxes, or text areas. Read only static text and link URLs.
            if role == (kAXStaticTextRole as String), Date() < deadline,
               let text = axString(element, kAXValueAttribute as String) {
                node["text"] = text; textCount += text.count
            }
            if role == "AXLink", Date() < deadline,
               let raw = axValue(element, kAXURLAttribute as String) {
                let rawString = (raw as? URL)?.absoluteString ?? (raw as? String)
                if let rawString, let url = safeURL(rawString) { node["url"] = url; textCount += url.count }
            }
        }
        nodes.append(node)
        let editable = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        guard !secure, !editable, entry.depth < 12, Date() < deadline else { continue }
        var rawChildren: CFArray?
        let maxChildren = min(50, 300 - pending.count)
        if maxChildren <= 0 { truncated = true; continue }
        if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, maxChildren, &rawChildren) == .success,
           let children = rawChildren as? [AXUIElement] {
            pending.append(contentsOf: children.map { Pending(element: $0, depth: entry.depth + 1, parent: index) })
            if children.count == maxChildren { truncated = true }
        }
    }
    context["accessibility"] = ["status": "captured", "nodes": nodes, "truncated": truncated,
                                  "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)] as [String: Any]
    return context
}

private struct CommandResult { let code: Int32; let output: String }

private func command(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // File output avoids a full pipe deadlocking the GUI on a verbose child.
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-capture-output-" + UUID().uuidString)
    FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
    process.standardOutput = output; process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
        process.terminate()
        let stopDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "操作等待超时。"])
    }
    process.waitUntilExit()
    let data = (try? Data(contentsOf: outputURL)) ?? Data()
    return CommandResult(code: process.terminationStatus, output: String(data: data.prefix(16_384), encoding: .utf8) ?? "")
}

private let terminalJobPhases: Set<String> = ["completed", "failed", "cancelled", "needs_input", "interrupted"]

private func jobPhaseLabel(_ phase: String) -> String {
    switch phase {
    case "queued", "connecting": return "准备任务"
    case "classifying": return "Luna 判断项目"
    case "creating_thread", "starting_initial": return "创建项目对话"
    case "running_initial", "initial_finished": return "执行中"
    case "starting_followup", "followup_finished": return "自动跟进"
    case "completed": return "流程已结束"
    case "cancelled": return "已取消"
    case "needs_input": return "需处理"
    case "failed": return "执行失败"
    case "interrupted": return "后台已中断"
    default: return "状态待确认"
    }
}

private struct JobSummary {
    let id: String
    let phase: String
    let project: String
    let createdAt: String
    var active: Bool { !terminalJobPhases.contains(phase) }
    var label: String { jobPhaseLabel(phase) }
    var display: String { (project.isEmpty ? String(id.prefix(8)) : project) + " · " + label }
    var json: [String: Any] { ["jobId": id, "phase": phase, "phaseLabel": label, "projectName": project] }
}

/// File-backed progress only: this never resumes a chat or reads another app.
private final class JobStatusReader {
    private struct CachedState { let modified: Date; let size: Int; let value: [String: Any] }
    private var cache: [String: CachedState] = [:]
    private let directory: URL

    init(directory: URL = dataDirectory) { self.directory = directory }

    func read() -> [JobSummary] {
        let jobs = directory.appendingPathComponent("jobs", isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            cache.removeAll(); return []
        }
        var seen = Set<String>()
        var result: [JobSummary] = []
        for directory in directories {
            let id = directory.lastPathComponent
            guard !id.isEmpty, id.allSatisfy({ "0123456789abcdef-".contains($0) }),
                  let directoryInfo = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  directoryInfo.isDirectory == true, directoryInfo.isSymbolicLink != true else { continue }
            let path = directory.appendingPathComponent("state.json")
            guard let info = try? path.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]),
                  info.isSymbolicLink != true, let modified = info.contentModificationDate,
                  let size = info.fileSize, size <= 1_048_576 else { continue }
            seen.insert(id)
            var record: [String: Any]
            if let cached = cache[id], cached.modified == modified, cached.size == size { record = cached.value }
            else {
                guard let bytes = try? Data(contentsOf: path),
                      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
                record = value; cache[id] = CachedState(modified: modified, size: size, value: value)
            }
            var phase = record["phase"] as? String ?? "needs_input"
            if !terminalJobPhases.contains(phase) {
                if let pid = record["workerPid"] as? Int {
                    if pid <= 1 || pid > Int(Int32.max) || kill(pid_t(pid), 0) != 0 { phase = "interrupted" }
                } else if Date().timeIntervalSince(modified) > 30 {
                    // A queued file may precede worker startup for a moment.
                    // Missing workers must not show as preparing forever.
                    phase = "interrupted"
                }
            }
            let project = (record["project"] as? [String: Any])?["name"] as? String ?? ""
            result.append(JobSummary(id: id, phase: phase, project: project, createdAt: record["createdAt"] as? String ?? ""))
        }
        cache = cache.filter { seen.contains($0.key) }
        return result.sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
    }
}

private final class CaptureDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var hotKeyStatus: OSStatus = -1
    private var busy = false
    private var state = "starting"
    private var lastError: String?
    private var lastJob: String?
    private var lastExternalApp: NSRunningApplication?
    private var appObserver: NSObjectProtocol?
    private var lastTrigger: Date?
    private var ownsStatusRecord = false
    private var progressTimer: Timer?
    private let statusReader = JobStatusReader()
    private let statusQueue = DispatchQueue(label: appID + ".job-status", qos: .utility)
    private var refreshingJobs = false
    private var activeJobs: [JobSummary] = []
    private var latestJob: JobSummary?
    private var guiOpening = false
    private var guiWarning: String?
    private var menuIsOpen = false
    private var screenCapturePermission = ScreenCapturePermissionState()
    private let startedAt = timestamp()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: appID).contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if duplicate { NSApp.terminate(nil); return }
        ownsStatusRecord = true
        screenCapturePermission.refresh(using: CGPreflightScreenCaptureAccess)
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != appID { self?.lastExternalApp = app }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Codex Capture")
        item.button?.toolTip = "Codex Capture · Option+S"
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<CaptureDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { owner.beginCapture() }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if handlerStatus == noErr {
            hotKeyStatus = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(optionKey), EventHotKeyID(signature: 0x43435850, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        } else { hotKeyStatus = handlerStatus }
        if hotKeyStatus == noErr { state = "ready" }
        else { state = "shortcut_unavailable"; lastError = "Option+S 注册失败（\(hotKeyStatus)）。可从菜单截图；没有自动改用其他快捷键。" }
        refreshMenu(); writeStatus(); refreshJobProgress()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshJobProgress() }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        progressTimer?.invalidate()
        state = "stopped"; writeStatus()
    }

    private func writeStatus() {
        guard ownsStatusRecord else { return }
        let registered = hotKeyStatus == noErr && hotKey != nil && state != "stopped"
        var data: [String: Any] = ["version": helperVersion, "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "state": state, "startedAt": startedAt, "updatedAt": timestamp(), "busy": busy,
            "shortcut": "Option+S", "registered": registered, "hotkeyRegistered": registered, "hotkeyStatus": Int(hotKeyStatus),
            "accessibilityEnabled": UserDefaults.standard.bool(forKey: axPreference),
            "accessibilityTrusted": AXIsProcessTrusted(), "screenCaptureAllowed": screenCapturePermission.allowed,
            "screenCaptureRequested": screenCapturePermission.requested,
            "activeJobs": activeJobs.map(\.json), "activeJobCount": activeJobs.count,
            "executable": Bundle.main.executableURL?.path ?? CommandLine.arguments[0]]
        if let lastError { data["lastError"] = lastError }
        if let checkedAt = screenCapturePermission.checkedAt { data["screenCaptureCheckedAt"] = checkedAt }
        if let lastJob { data["lastJobId"] = lastJob }
        if let latestJob { data["latestJobPhase"] = latestJob.phase; data["latestJobPhaseLabel"] = latestJob.label }
        if let guiWarning { data["guiWarning"] = guiWarning }
        if let lastTrigger { data["lastTriggerAt"] = ISO8601DateFormatter().string(from: lastTrigger) }
        try? writeJSON(data, to: statusURL)
    }

    private func refreshMenu() {
        item.button?.title = activeJobs.isEmpty ? "" : " \(activeJobs.count)"
        item.button?.toolTip = "Codex Capture · Option+S" + (latestJob.map { "\n最近任务：" + $0.display } ?? "")
        guard !menuIsOpen else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let title = hotKeyStatus == noErr ? "截图并开始任务（⌥S）" : "截图并开始任务（快捷键不可用）"
        let capture = menu.addItem(withTitle: title, action: #selector(captureFromMenu), keyEquivalent: "")
        capture.target = self; capture.isEnabled = !busy
        let progressText = state == "permission_required" ? "屏幕录制待授权；请打开下方权限设置" : activeJobs.isEmpty ? "没有进行中的任务" : "\(activeJobs.count) 个任务进行中：" + activeJobs[0].label
        let progress = menu.addItem(withTitle: busy ? "正在截图或提交…" : progressText, action: nil, keyEquivalent: "")
        progress.isEnabled = false
        let workbench = menu.addItem(withTitle: guiOpening ? "正在打开任务工作台…" : "任务工作台…", action: #selector(showWorkbench), keyEquivalent: "")
        workbench.target = self; workbench.isEnabled = !busy && !guiOpening
        if let latestJob {
            let recent = menu.addItem(withTitle: "最近任务：" + latestJob.display, action: #selector(showLatestJob), keyEquivalent: "")
            recent.target = self; recent.isEnabled = !busy && !guiOpening
        }
        menu.addItem(.separator())
        let enabled = UserDefaults.standard.bool(forKey: axPreference)
        let ax = menu.addItem(withTitle: "附带前景窗口无障碍信息（可选）", action: #selector(toggleAccessibility), keyEquivalent: "")
        ax.target = self; ax.state = enabled ? .on : .off; ax.isEnabled = !busy
        if enabled && !AXIsProcessTrusted() {
            let permission = menu.addItem(withTitle: "打开无障碍授权设置…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            permission.target = self
        }
        let recording = menu.addItem(withTitle: screenCapturePermission.allowed ? "屏幕录制权限设置…" : "屏幕录制待授权：打开设置…", action: #selector(openScreenSettings), keyEquivalent: "")
        recording.target = self
        menu.addItem(.separator())
        let records = menu.addItem(withTitle: "打开日志文件夹", action: #selector(showRecords), keyEquivalent: "")
        records.target = self
        let refresh = menu.addItem(withTitle: "刷新权限状态", action: #selector(refreshPermissions), keyEquivalent: "")
        refresh.target = self
        let quit = menu.addItem(withTitle: "退出 Codex Capture", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self; quit.isEnabled = !busy
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false; refreshMenu() }

    private func refreshJobProgress() {
        guard !refreshingJobs else { return }
        refreshingJobs = true
        statusQueue.async {
            let summaries = self.statusReader.read()
            DispatchQueue.main.async {
                self.refreshingJobs = false
                self.activeJobs = summaries.filter(\.active)
                // A scan begun just before submission must not replace the new
                // job with the older result. The next poll will include it.
                if self.lastJob == nil || summaries.contains(where: { $0.id == self.lastJob }) {
                    self.latestJob = summaries.first
                    self.lastJob = summaries.first?.id
                }
                self.refreshMenu(); self.writeStatus()
            }
        }
    }

    private func openWorkbench(jobID: String?, showError: Bool = false) {
        guard !guiOpening else { return }
        guiOpening = true; guiWarning = nil; refreshMenu(); writeStatus()
        let arguments = ["gui"] + (jobID.map { ["--job", $0] } ?? [])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try command(launcherURL.path, arguments, timeout: 30)
                DispatchQueue.main.async {
                    self.guiOpening = false
                    if result.code != 0 {
                        self.guiWarning = "工作台未能打开；已提交的任务不受影响。" + String(result.output.prefix(2000))
                        if showError { self.alert("任务工作台未能打开", self.guiWarning!) }
                    }
                    self.refreshMenu(); self.writeStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    self.guiOpening = false
                    self.guiWarning = "工作台未能打开；已提交的任务不受影响。" + error.localizedDescription
                    if showError { self.alert("任务工作台未能打开", self.guiWarning!) }
                    self.refreshMenu(); self.writeStatus()
                }
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "好"); alert.runModal()
    }

    @objc private func captureFromMenu() { beginCapture() }
    @objc private func refreshPermissions() {
        screenCapturePermission.refresh(using: CGPreflightScreenCaptureAccess)
        if screenCapturePermission.allowed && state == "permission_required" {
            state = hotKeyStatus == noErr ? "ready" : "shortcut_unavailable"
            lastError = nil
        }
        refreshMenu(); writeStatus()
    }
    @objc private func showRecords() { NSWorkspace.shared.open(dataDirectory) }
    @objc private func showWorkbench() { openWorkbench(jobID: nil, showError: true) }
    @objc private func showLatestJob() { openWorkbench(jobID: lastJob, showError: true) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refreshMenu(); writeStatus()
    }
    @objc private func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func toggleAccessibility() {
        let enabled = UserDefaults.standard.bool(forKey: axPreference)
        if enabled { UserDefaults.standard.set(false, forKey: axPreference) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            let prompt = NSAlert()
            prompt.messageText = "附带前景窗口的无障碍信息？"
            prompt.informativeText = "仅在你触发截图时，读取当时前景窗口的标题、标签和部分静态文字，随截图交给 Codex 帮助判断项目。密码及输入框内容会跳过。macOS 需要你为 Codex Capture 开启无障碍权限；不授权也能继续截图。"
            prompt.addButton(withTitle: "启用"); prompt.addButton(withTitle: "取消")
            guard prompt.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: axPreference)
            if !AXIsProcessTrusted() { openAccessibilitySettings() }
        }
        refreshMenu(); writeStatus()
    }

    fileprivate func beginCapture() {
        guard !busy else { return }
        if let lastTrigger, Date().timeIntervalSince(lastTrigger) < 0.4 { return }
        lastTrigger = Date(); lastError = nil
        guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
            alert("尚未安装任务入口", "请重新运行插件的 install.sh。\n" + launcherURL.path); return
        }
        busy = true; state = "capturing"; refreshMenu(); writeStatus()
        // Capture source identity before any permission dialog, screen selection,
        // or our text input window can become the foreground application.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let source = frontmost?.bundleIdentifier == appID ? lastExternalApp : frontmost
        let context = foregroundContext(source, includeAX: UserDefaults.standard.bool(forKey: axPreference))
        if !screenCapturePermission.allowsCapture(check: CGPreflightScreenCaptureAccess, request: CGRequestScreenCaptureAccess) {
            lastError = "当前助手尚未获得屏幕录制权限；请从菜单打开权限设置，授权后按系统提示重新打开助手。"
            state = "permission_required"
            // macOS owns the authorization dialog. Do not stack another modal
            // on top of it or re-request authorization on every hotkey press.
            finishCapture(); return
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("codex-capture-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { fail(error, temporary: nil); return }
        let screenshot = temporary.appendingPathComponent("screenshot.png")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try command("/usr/sbin/screencapture", ["-i", "-x", screenshot.path], timeout: 180)
                DispatchQueue.main.async {
                    guard FileManager.default.fileExists(atPath: screenshot.path) else {
                        // Escape cancels the native screenshot without submitting.
                        if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.fail(NSError(domain: appID, code: Int(result.code), userInfo: [NSLocalizedDescriptionKey: "系统截图失败。" + result.output]), temporary: temporary)
                        } else { self.state = "ready"; self.finishCapture(temporary: temporary) }
                        return
                    }
                    guard result.code == 0 else {
                        self.fail(NSError(domain: appID, code: Int(result.code), userInfo: [NSLocalizedDescriptionKey: "系统截图失败。" + result.output]), temporary: temporary); return
                    }
                    self.askDescription(screenshot: screenshot, context: context, temporary: temporary)
                }
            } catch { DispatchQueue.main.async { self.fail(error, temporary: temporary) } }
        }
    }

    private func askDescription(screenshot: URL, context: [String: Any], temporary: URL) {
        state = "awaiting_description"; writeStatus()
        NSApp.activate(ignoringOtherApps: true)
        let prompt = NSAlert(); prompt.messageText = "希望 Codex 做什么？"
        prompt.informativeText = "Luna 会根据截图和描述选择项目，并立即在后台开始任务。"
        prompt.addButton(withTitle: "开始任务"); prompt.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 28))
        input.placeholderString = "描述你希望完成的任务"
        prompt.accessoryView = input
        prompt.window.initialFirstResponder = input
        var description = ""
        while true {
            let result = prompt.runModal()
            guard result == .alertFirstButtonReturn else { state = "ready"; finishCapture(temporary: temporary); return }
            description = input.stringValue
            let isEmpty = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isEmpty && description.count <= 5_000 { break }
            prompt.informativeText = isEmpty ? "请输入任务描述，然后选择「开始任务」。" : "描述请控制在 5000 字以内。"
        }
        state = "submitting"; writeStatus()
        let contextFile = temporary.appendingPathComponent("context.json")
        do { try writeJSON(context, to: contextFile) }
        catch { fail(error, temporary: temporary); return }
        let submittedText = description
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try command(launcherURL.path, submissionArguments(image: screenshot.path, text: submittedText, context: contextFile.path), timeout: 30)
                DispatchQueue.main.async {
                    guard result.code == 0,
                          let data = result.output.data(using: .utf8),
                          let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let job = reply["jobId"] as? String else {
                        self.fail(NSError(domain: appID, code: Int(result.code), userInfo: [NSLocalizedDescriptionKey: "提交失败。" + result.output]), temporary: temporary); return
                    }
                    self.lastJob = job; self.state = "ready"
                    self.latestJob = JobSummary(id: job, phase: "queued", project: "", createdAt: timestamp())
                    self.finishCapture(temporary: temporary)
                    self.refreshJobProgress()
                    self.openWorkbench(jobID: job)
                    self.item.button?.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "任务已开始")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Codex Capture")
                    }
                }
            } catch { DispatchQueue.main.async { self.fail(error, temporary: temporary) } }
        }
    }

    private func fail(_ error: Error, temporary: URL?) {
        lastError = error.localizedDescription; state = "error"
        alert("Codex Capture 未能开始任务", error.localizedDescription)
        finishCapture(temporary: temporary)
    }
    private func finishCapture(temporary: URL? = nil) {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        busy = false; refreshMenu(); writeStatus()
    }
}

if CommandLine.arguments.contains("--self-test") {
    var permission = ScreenCapturePermissionState()
    var permissionRequests = 0
    let deniedRequest = { permissionRequests += 1; return false }
    precondition(!permission.allowsCapture(check: { false }, request: deniedRequest))
    precondition(!permission.allowsCapture(check: { false }, request: deniedRequest))
    permission.refresh(using: { false })
    precondition(!permission.allowsCapture(check: { false }, request: deniedRequest))
    precondition(permissionRequests == 1 && permission.requested && !permission.allowed)
    precondition(permission.allowsCapture(check: { true }, request: deniedRequest))
    precondition(permissionRequests == 1 && permission.allowed)
    precondition(!permission.allowsCapture(check: { false }, request: deniedRequest))
    precondition(permissionRequests == 1)
    var alreadyAllowed = ScreenCapturePermissionState()
    precondition(alreadyAllowed.allowsCapture(check: { true }, request: deniedRequest))
    precondition(permissionRequests == 1 && !alreadyAllowed.requested)
    var newlyAllowed = ScreenCapturePermissionState()
    precondition(newlyAllowed.allowsCapture(check: { false }, request: { true }))
    precondition(newlyAllowed.allowed && newlyAllowed.requested)
    let originalDescription = "- 原文\n  保留空格与换行  \n"
    precondition(submissionArguments(image: "/tmp/image.png", text: originalDescription, context: "/tmp/context.json") == ["submit", "--image", "/tmp/image.png", "--text=" + originalDescription, "--context-file", "/tmp/context.json"])
    precondition(safeURL("https://user:password@example.com/project?token=secret#fragment") == "https://example.com/project")
    precondition(safeURL("javascript:alert(1)") == nil)
    precondition(safeURL("https://example.com/a") == "https://example.com/a")
    precondition(jobPhaseLabel("classifying") == "Luna 判断项目")
    precondition(jobPhaseLabel("starting_followup") == "自动跟进")
    precondition(!JobSummary(id: "fixture", phase: "completed", project: "Demo", createdAt: "").active)
    precondition(JobSummary(id: "fixture", phase: "running_initial", project: "Demo", createdAt: "").active)
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("capture-status-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let stateA = fixture.appendingPathComponent("jobs/abc/state.json")
    let stateB = fixture.appendingPathComponent("jobs/def/state.json")
    try FileManager.default.createDirectory(at: stateA.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: stateB.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeJSON(["phase": "completed", "createdAt": "2026-10-28T00:00:00Z"], to: stateA)
    try writeJSON(["phase": "running_initial", "workerPid": 0, "createdAt": "2026-10-29T00:00:00Z"], to: stateB)
    let reader = JobStatusReader(directory: fixture)
    let initial = reader.read()
    precondition(initial.count == 2 && initial[0].id == "def" && initial[0].phase == "interrupted")
    try writeJSON(["phase": "failed", "createdAt": "2026-10-29T00:00:00Z"], to: stateB)
    precondition(reader.read()[0].phase == "failed")
    print("{\"selfTest\":\"passed\",\"version\":\"\(helperVersion)\"}")
} else if CommandLine.arguments.contains("--check") {
    // Only the running helper's persisted status represents its permissions.
    // A CLI probe can inherit different permissions from its invoking terminal,
    // so do not run authorization preflights in this short-lived process.
    var status: [String: Any] = ["version": helperVersion, "bundleId": Bundle.main.bundleIdentifier ?? appID,
        "launcherExists": FileManager.default.isExecutableFile(atPath: launcherURL.path),
        "statusPath": statusURL.path, "shortcut": "Option+S"]
    if let existing = try? Data(contentsOf: statusURL),
       let running = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
        status["helper"] = running
        if let pid = running["pid"] as? Int { status["processRunning"] = kill(pid_t(pid), 0) == 0 }
    }
    let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = CaptureDelegate()
    app.delegate = delegate
    app.run()
}
