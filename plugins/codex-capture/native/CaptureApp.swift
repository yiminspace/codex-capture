import AppKit
import ApplicationServices
import Carbon
import Foundation

private let appID = "com.yiminlab.codex-capture"
private let helperVersion = "0.5.1"
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

private func submissionArguments(preparationID: String, text: String) -> [String] {
    // Keep the user's text byte-for-byte, including leading dashes and whitespace.
    ["submit", "--preparation-id", preparationID, "--text=" + text]
}

private func validDescription(_ text: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 5_000
}

private struct RecognitionProgress: Equatable {
    let title: String
    let detail: String
    let loading: Bool
    let failed: Bool

    static let identifying = RecognitionProgress(title: "正在识别项目…", detail: "你可以同时输入需求。", loading: true, failed: false)

    init(state: [String: Any]) {
        switch state["phase"] as? String ?? "" {
        case "queued", "connecting", "classifying": self = .identifying
        case "ready":
            let name = (state["project"] as? [String: Any])?["name"] as? String ?? ""
            if name.isEmpty {
                self.init(title: "无法确认项目", detail: "识别结果缺少项目名称，请取消后重新截图。", loading: false, failed: true)
            } else {
                self.init(title: "项目：" + name, detail: "开始后将在这个项目执行任务。", loading: false, failed: false)
            }
        case "needs_input", "failed", "cancelled":
            self.init(title: "项目识别未完成", detail: String((state["error"] as? String ?? "请取消后重新截图。").prefix(500)), loading: false, failed: true)
        default:
            self.init(title: "项目状态不可用", detail: "请取消后重新截图。", loading: false, failed: true)
        }
    }

    init(title: String, detail: String, loading: Bool, failed: Bool) {
        self.title = title; self.detail = detail; self.loading = loading; self.failed = failed
    }
}

private func preparationReply(_ output: String) -> (id: String, stateURL: URL, workerPID: Int?)? {
    guard let data = output.data(using: .utf8),
          let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = reply["preparationId"] as? String, UUID(uuidString: id) != nil,
          let statePath = reply["statePath"] as? String else { return nil }
    let expected = dataDirectory.appendingPathComponent("preparations/" + id + "/state.json").standardizedFileURL.resolvingSymlinksInPath()
    let actual = URL(fileURLWithPath: statePath).standardizedFileURL.resolvingSymlinksInPath()
    guard actual == expected else { return nil }
    let pid = reply["workerPid"] as? Int
    return (id, actual, pid.flatMap { $0 > 1 && $0 <= Int(Int32.max) ? $0 : nil })
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

/// A modeless window keeps editing, image preview and recognition progress live
/// at the same time. Native semantic colors also follow the system appearance.
private final class CaptureInputWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onSubmit: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onEscape?(); return true }
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { onSubmit?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class CaptureInputController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let textView = NSTextView()
    private let spinner = NSProgressIndicator()
    private let statusIcon = NSImageView()
    private let projectLabel = NSTextField(labelWithString: RecognitionProgress.identifying.title)
    private let detailLabel = NSTextField(wrappingLabelWithString: RecognitionProgress.identifying.detail)
    private let messageLabel = NSTextField(wrappingLabelWithString: "⌘ Return 开始任务 · Return 换行")
    private let startButton = NSButton(title: "开始任务", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var progress = RecognitionProgress.identifying
    private var submitting = false
    private var cancellable = true
    private var dismissed = false

    init(image: NSImage) {
        let window = CaptureInputWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 530), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Capture"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onEscape = { [weak self] in self?.cancelInput(nil) }
        window.onSubmit = { [weak self] in self?.submitInput(nil) }

        let content = NSView()
        window.contentView = content
        let preview = NSImageView()
        preview.image = image; preview.imageScaling = .scaleProportionallyUpOrDown
        // A large screenshot must fit this window, never enlarge it to the
        // image's intrinsic pixel size (multi-display captures can be huge).
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.setAccessibilityLabel("本次截图预览")
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true

        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isIndeterminate = true; spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("正在识别项目")
        statusIcon.imageScaling = .scaleProportionallyDown
        projectLabel.font = .systemFont(ofSize: 13, weight: .medium)
        projectLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        let projectText = NSStackView(views: [projectLabel, detailLabel])
        projectText.orientation = .vertical; projectText.alignment = .leading; projectText.spacing = 3
        let iconArea = NSView()
        for item in [spinner, statusIcon] { item.translatesAutoresizingMaskIntoConstraints = false; iconArea.addSubview(item) }
        NSLayoutConstraint.activate([
            iconArea.widthAnchor.constraint(equalToConstant: 18),
            iconArea.heightAnchor.constraint(equalToConstant: 18),
            spinner.centerXAnchor.constraint(equalTo: iconArea.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconArea.centerYAnchor),
            statusIcon.leadingAnchor.constraint(equalTo: iconArea.leadingAnchor),
            statusIcon.trailingAnchor.constraint(equalTo: iconArea.trailingAnchor),
            statusIcon.topAnchor.constraint(equalTo: iconArea.topAnchor),
            statusIcon.bottomAnchor.constraint(equalTo: iconArea.bottomAnchor),
        ])
        let recognition = NSStackView(views: [iconArea, projectText])
        recognition.orientation = .horizontal; recognition.alignment = .top; recognition.spacing = 9

        let heading = NSTextField(labelWithString: "希望 Codex 做什么？")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let editor = NSScrollView()
        editor.borderType = .bezelBorder
        editor.hasVerticalScroller = true
        editor.autohidesScrollers = true
        editor.drawsBackground = true
        textView.font = .systemFont(ofSize: 14)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 9, height: 9)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("任务描述")
        editor.documentView = textView

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 2
        startButton.bezelStyle = .rounded
        startButton.target = self; startButton.action = #selector(submitInput)
        startButton.keyEquivalent = "\r"; startButton.keyEquivalentModifierMask = .command
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self; cancelButton.action = #selector(cancelInput)
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        let buttons = NSStackView(views: [cancelButton, startButton])
        buttons.orientation = .horizontal; buttons.spacing = 8

        for item in [preview, recognition, heading, editor, messageLabel, buttons] {
            item.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(item)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            preview.heightAnchor.constraint(equalToConstant: 220),
            recognition.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 14),
            recognition.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            recognition.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            recognition.heightAnchor.constraint(equalToConstant: 44),
            heading.topAnchor.constraint(equalTo: recognition.bottomAnchor, constant: 10),
            heading.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            editor.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            editor.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            editor.heightAnchor.constraint(equalToConstant: 100),
            messageLabel.topAnchor.constraint(equalTo: editor.bottomAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            messageLabel.heightAnchor.constraint(equalToConstant: 28),
            buttons.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
        window.initialFirstResponder = textView
        window.center()
        updateRecognition(.identifying)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    func updateRecognition(_ value: RecognitionProgress) {
        progress = value
        projectLabel.stringValue = value.title
        detailLabel.stringValue = value.detail
        detailLabel.toolTip = value.detail
        projectLabel.textColor = value.failed ? .systemRed : .labelColor
        statusIcon.isHidden = value.loading
        statusIcon.image = NSImage(systemSymbolName: value.failed ? "exclamationmark.circle" : "checkmark.circle.fill", accessibilityDescription: value.failed ? "项目识别未完成" : "已识别项目")
        statusIcon.contentTintColor = value.failed ? .systemRed : .systemGreen
        if value.loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refreshControls()
    }

    func setSubmitting(_ value: Bool, awaitingPreparation: Bool = false) {
        submitting = value
        cancellable = !value || awaitingPreparation
        messageLabel.stringValue = value ? (awaitingPreparation ? "正在准备项目识别，随后开始任务…" : "正在创建任务…") : "⌘ Return 开始任务 · Return 换行"
        messageLabel.textColor = .secondaryLabelColor
        refreshControls()
    }

    func showSubmissionError(_ message: String) {
        setSubmitting(false)
        messageLabel.stringValue = String(message.prefix(500))
        messageLabel.toolTip = message
        messageLabel.textColor = .systemRed
        window?.makeFirstResponder(textView)
    }

    func dismiss() {
        dismissed = true
        window?.orderOut(nil)
        close()
    }

    private func refreshControls() {
        startButton.isEnabled = !submitting && !progress.failed && validDescription(textView.string)
        cancelButton.isEnabled = cancellable
        window?.standardWindowButton(.closeButton)?.isEnabled = cancellable
        textView.isEditable = !submitting
    }

    func textDidChange(_ notification: Notification) {
        if !submitting {
            messageLabel.stringValue = textView.string.count > 5_000 ? "描述请控制在 5000 字以内。" : "⌘ Return 开始任务 · Return 换行"
            messageLabel.textColor = textView.string.count > 5_000 ? .systemRed : .secondaryLabelColor
        }
        refreshControls()
    }

    @objc private func submitInput(_ sender: Any?) {
        guard !submitting, !progress.failed, validDescription(textView.string) else { return }
        onSubmit?(textView.string)
    }

    @objc private func cancelInput(_ sender: Any?) {
        guard cancellable, !dismissed else { return }
        onCancel?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if dismissed { return true }
        guard cancellable else { return false }
        onCancel?()
        return false
    }
}

private final class CaptureInputSession {
    let controller: CaptureInputController
    let temporary: URL
    var preparationID: String?
    var stateURL: URL?
    var preparationWorkerPID: Int?
    var pollTimer: Timer?
    var preparationReturned = false
    var preparationFinished = false
    var cancelled = false
    var pendingDescription: String?
    var submissionInFlight = false
    let startedAt = Date()

    init(controller: CaptureInputController, temporary: URL) {
        self.controller = controller; self.temporary = temporary
    }

    deinit { pollTimer?.invalidate() }
}

private let terminalJobPhases: Set<String> = ["completed", "failed", "cancelled", "needs_input", "interrupted"]

private func jobPhaseLabel(_ phase: String) -> String {
    switch phase {
    case "queued", "connecting": return "准备任务"
    case "classifying", "waiting_preparation": return "Luna 判断项目"
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
    private var inputSession: CaptureInputSession?
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
        if let inputSession { cancelInputSession(inputSession) }
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
        guard let image = NSImage(contentsOf: screenshot) else {
            fail(NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取本次截图，请重新截图。"]), temporary: temporary)
            return
        }
        let contextFile = temporary.appendingPathComponent("context.json")
        do { try writeJSON(context, to: contextFile) }
        catch { fail(error, temporary: temporary); return }
        let controller = CaptureInputController(image: image)
        let session = CaptureInputSession(controller: controller, temporary: temporary)
        inputSession = session
        controller.onSubmit = { [weak self, weak session] text in
            guard let self, let session, self.inputSession === session else { return }
            session.pendingDescription = text
            session.controller.setSubmitting(true, awaitingPreparation: session.preparationID == nil)
            self.state = "submitting"; self.writeStatus()
            self.submitPreparedSession(session)
        }
        controller.onCancel = { [weak self, weak session] in
            guard let self, let session else { return }
            self.cancelInputSession(session)
        }
        state = "awaiting_description"; writeStatus()
        controller.present()
        // The window is already editable while the short CLI call starts a
        // detached classifier. No user description is needed for this stage.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try command(launcherURL.path, ["prepare", "--image", screenshot.path, "--context-file", contextFile.path], timeout: 30)
                let prepared = preparationReply(result.output)
                DispatchQueue.main.async {
                    session.preparationReturned = true
                    guard self.inputSession === session, !session.cancelled else {
                        if let prepared { self.discardPreparation(prepared.id) }
                        try? FileManager.default.removeItem(at: temporary)
                        return
                    }
                    if let prepared {
                        // Retain a known handle even when the launcher reports
                        // an error, so cancellation can still stop its worker.
                        session.preparationID = prepared.id
                        session.stateURL = prepared.stateURL
                        session.preparationWorkerPID = prepared.workerPID
                    }
                    guard result.code == 0, prepared != nil else {
                        self.preparationFailed(session, message: "无法开始项目识别。" + String(result.output.prefix(1500)))
                        return
                    }
                    self.startPreparationPolling(session)
                    self.submitPreparedSession(session)
                }
            } catch {
                DispatchQueue.main.async {
                    session.preparationReturned = true
                    guard self.inputSession === session, !session.cancelled else {
                        try? FileManager.default.removeItem(at: temporary)
                        return
                    }
                    self.preparationFailed(session, message: "无法开始项目识别。" + error.localizedDescription)
                }
            }
        }
    }

    private func preparationFailed(_ session: CaptureInputSession, message: String) {
        guard inputSession === session else { return }
        session.pendingDescription = nil
        session.preparationFinished = true
        session.pollTimer?.invalidate(); session.pollTimer = nil
        if let preparationID = session.preparationID { discardPreparation(preparationID) }
        session.controller.setSubmitting(false)
        session.controller.updateRecognition(RecognitionProgress(title: "项目识别未完成", detail: message, loading: false, failed: true))
        lastError = message; state = "awaiting_description"; writeStatus()
    }

    private func startPreparationPolling(_ session: CaptureInputSession) {
        guard inputSession === session, !session.cancelled, !session.submissionInFlight, !session.preparationFinished else { return }
        pollPreparation(session)
        guard !session.preparationFinished, session.pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.pollPreparation(session)
        }
        RunLoop.main.add(timer, forMode: .common)
        session.pollTimer = timer
    }

    private func pollPreparation(_ session: CaptureInputSession) {
        guard inputSession === session, !session.cancelled, !session.submissionInFlight, let stateURL = session.stateURL else { return }
        guard let info = try? stateURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              info.isSymbolicLink != true, let size = info.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: stateURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if Date().timeIntervalSince(session.startedAt) > 30 {
                preparationFailed(session, message: "无法读取项目识别状态，请取消后重新截图。")
            }
            return
        }
        let progress = RecognitionProgress(state: record)
        session.controller.updateRecognition(progress)
        if !progress.loading {
            session.preparationFinished = true
            session.pollTimer?.invalidate(); session.pollTimer = nil
            if progress.failed && !session.submissionInFlight {
                session.pendingDescription = nil
                session.controller.setSubmitting(false)
                lastError = progress.detail; state = "awaiting_description"; writeStatus()
            }
        } else if let pid = record["workerPid"] as? Int ?? session.preparationWorkerPID,
                  pid <= 1 || pid > Int(Int32.max) || kill(pid_t(pid), 0) != 0 {
            preparationFailed(session, message: "项目识别进程已退出，请取消后重新截图。")
        } else if record["workerPid"] == nil && session.preparationWorkerPID == nil && Date().timeIntervalSince(session.startedAt) > 10 {
            preparationFailed(session, message: "项目识别进程未能启动，请取消后重新截图。")
        } else if Date().timeIntervalSince(session.startedAt) > 300 {
            preparationFailed(session, message: "项目识别等待超时，请取消后重新截图。")
        }
    }

    private func submitPreparedSession(_ session: CaptureInputSession) {
        guard inputSession === session, !session.cancelled, !session.submissionInFlight,
              let preparationID = session.preparationID, let text = session.pendingDescription else { return }
        session.submissionInFlight = true
        session.pollTimer?.invalidate(); session.pollTimer = nil
        session.controller.setSubmitting(true)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try command(launcherURL.path, submissionArguments(preparationID: preparationID, text: text), timeout: 30)
                DispatchQueue.main.async {
                    guard self.inputSession === session, !session.cancelled else { return }
                    session.submissionInFlight = false
                    guard result.code == 0,
                          let data = result.output.data(using: .utf8),
                          let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let job = reply["jobId"] as? String else {
                        session.pendingDescription = nil
                        session.controller.showSubmissionError("提交失败，描述已保留。" + String(result.output.prefix(1000)))
                        self.startPreparationPolling(session)
                        self.state = "awaiting_description"; self.writeStatus()
                        return
                    }
                    self.lastJob = job; self.state = "ready"
                    self.latestJob = JobSummary(id: job, phase: "queued", project: "", createdAt: timestamp())
                    session.pollTimer?.invalidate()
                    session.controller.dismiss()
                    self.inputSession = nil
                    self.finishCapture(temporary: session.temporary)
                    self.refreshJobProgress()
                    self.openWorkbench(jobID: job)
                    self.item.button?.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "任务已开始")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Codex Capture")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.inputSession === session, !session.cancelled else { return }
                    session.submissionInFlight = false; session.pendingDescription = nil
                    session.controller.showSubmissionError("提交失败，描述已保留。" + error.localizedDescription)
                    self.startPreparationPolling(session)
                    self.state = "awaiting_description"; self.writeStatus()
                }
            }
        }
    }

    private func discardPreparation(_ preparationID: String) {
        // Cancellation starts a real CLI child immediately, including on app
        // termination; a global queue alone could be abandoned during exit.
        let process = Process()
        process.executableURL = launcherURL
        process.arguments = ["discard-preparation", preparationID]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).async { process.waitUntilExit() }
        } catch {
            // A late cancellation callback must not change a newer session's UI.
            fputs("Codex Capture: project recognition cancellation could not start.\n", stderr)
        }
    }

    private func cancelInputSession(_ session: CaptureInputSession) {
        guard inputSession === session, !session.submissionInFlight else { return }
        session.cancelled = true
        session.pollTimer?.invalidate(); session.pollTimer = nil
        session.controller.dismiss()
        if let preparationID = session.preparationID { discardPreparation(preparationID) }
        inputSession = nil
        state = "ready"
        // prepare may still be copying these inputs. Its completion callback
        // owns cleanup until the command has returned, even after this closes.
        finishCapture(temporary: session.preparationReturned ? session.temporary : nil)
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

/// Synthetic content for local visual QA. This mode never initializes the
/// menu-bar delegate, reads another application, or invokes a model/launcher.
private final class CapturePreviewDelegate: NSObject, NSApplicationDelegate {
    private var controller: CaptureInputController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let image = NSImage(size: NSSize(width: 960, height: 540))
        image.lockFocus()
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 960, height: 540)).fill()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 180, y: 0, width: 780, height: 540)).fill()
        func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, secondary: Bool = false) {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                .foregroundColor: secondary ? NSColor.darkGray : NSColor.black,
            ])
        }
        label("Demo Notes", x: 24, y: 492, size: 21, bold: true)
        label("全部笔记", x: 24, y: 414, size: 17)
        label("收藏", x: 24, y: 370, size: 17, secondary: true)
        label("归档", x: 24, y: 326, size: 17, secondary: true)
        label("旅行清单", x: 228, y: 466, size: 31, bold: true)
        label("最近更新：今天", x: 228, y: 424, size: 15, secondary: true)
        NSColor(calibratedRed: 0.86, green: 0.92, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 228, y: 359, width: 82, height: 30), xRadius: 6, yRadius: 6).fill()
        label("出行", x: 250, y: 365, size: 15)
        for (index, text) in ["确认车票和住宿", "整理需要携带的物品", "保存地图和行程"].enumerated() {
            let y = CGFloat(286 - index * 58)
            NSColor.lightGray.setStroke()
            NSBezierPath(roundedRect: NSRect(x: 230, y: y, width: 18, height: 18), xRadius: 3, yRadius: 3).stroke()
            label(text, x: 265, y: y - 2, size: 19)
        }
        image.unlockFocus()
        let controller = CaptureInputController(image: image)
        self.controller = controller
        controller.onCancel = { controller.dismiss(); NSApp.terminate(nil) }
        controller.onSubmit = { _ in controller.showSubmissionError("这是界面预览，不会创建任务。") }
        controller.present()
        if !CommandLine.arguments.contains("--preview-loading") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.controller?.updateRecognition(RecognitionProgress(state: ["phase": "ready", "project": ["name": "Demo Notes"]]))
            }
        }
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
    precondition(submissionArguments(preparationID: "fixture", text: originalDescription) == ["submit", "--preparation-id", "fixture", "--text=" + originalDescription])
    precondition(validDescription(originalDescription))
    precondition(!validDescription("  \n "))
    precondition(validDescription(String(repeating: "字", count: 5_000)))
    precondition(!validDescription(String(repeating: "字", count: 5_001)))
    precondition(RecognitionProgress(state: ["phase": "classifying"]) == .identifying)
    let recognized = RecognitionProgress(state: ["phase": "ready", "project": ["name": "Fixture"]])
    precondition(!recognized.loading && !recognized.failed && recognized.title == "项目：Fixture")
    precondition(RecognitionProgress(state: ["phase": "ready"]).failed)
    precondition(RecognitionProgress(state: ["phase": "failed", "error": "fixture failure"]).detail == "fixture failure")
    let preparationID = "00000000-0000-4000-8000-000000000001"
    let expectedState = dataDirectory.appendingPathComponent("preparations/" + preparationID + "/state.json").path
    let validReply = try JSONSerialization.data(withJSONObject: ["preparationId": preparationID, "statePath": expectedState])
    precondition(preparationReply(String(data: validReply, encoding: .utf8)!)?.id == preparationID)
    let liveReply = try JSONSerialization.data(withJSONObject: ["preparationId": preparationID, "statePath": expectedState, "workerPid": 123])
    precondition(preparationReply(String(data: liveReply, encoding: .utf8)!)?.workerPID == 123)
    let wrongReply = try JSONSerialization.data(withJSONObject: ["preparationId": preparationID, "statePath": "/tmp/unrelated.json"])
    precondition(preparationReply(String(data: wrongReply, encoding: .utf8)!) == nil)
    precondition(preparationReply("not json") == nil)
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
} else if CommandLine.arguments.contains("--preview-input") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = CapturePreviewDelegate()
    app.delegate = delegate
    app.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = CaptureDelegate()
    app.delegate = delegate
    app.run()
}
