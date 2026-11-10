import AppKit
import ApplicationServices
import Carbon
import Foundation
import ScreenCaptureKit

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

private func submissionArguments(preparationID: String, text: String, annotatedImage: String? = nil, startConversation: Bool = false) -> [String] {
    // Keep the user's text byte-for-byte, including leading dashes and whitespace.
    var arguments = ["submit", "--preparation-id", preparationID, "--text=" + text]
    if let annotatedImage { arguments += ["--annotated-image", annotatedImage] }
    if startConversation { arguments.append("--start-conversation") }
    return arguments
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
    url.user = nil; url.password = nil; url.query = nil
    url.fragment = url.fragment.flatMap { $0.hasPrefix("/") ? String($0.split(separator: "?", maxSplits: 1)[0]) : nil }
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

private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute as String),
          let size = axValue(element, kAXSizeAttribute as String),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
    let frame = CGRect(origin: point, size: dimensions)
    return frame.isEmpty ? nil : frame
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
    let viewport = axFrame(window)
    if let viewport {
        context["windowBounds"] = [viewport.minX, viewport.minY, viewport.width, viewport.height]
    }
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
        if let viewport, let frame = axFrame(element), !viewport.intersects(frame) { continue }
        if (axValue(element, "AXHidden") as? Bool) == true { continue }
        guard let role = axString(element, kAXRoleAttribute as String) else { continue }
        if role == "AXWebArea", let raw = axValue(element, kAXURLAttribute as String),
           let url = safeURL((raw as? URL)?.absoluteString ?? (raw as? String) ?? "") {
            windowInfo["url"] = url
            context["window"] = windowInfo
        }
        let subrole = axString(element, kAXSubroleAttribute as String) ?? ""
        let secure = subrole.localizedCaseInsensitiveContains("secure") || role.localizedCaseInsensitiveContains("secure")
        var node: [String: Any] = ["role": role, "depth": entry.depth]
        if !subrole.isEmpty { node["subrole"] = subrole }
        if let parent = entry.parent { node["parent"] = parent }
        let index = nodes.count
        if !secure {
            if ["AXRow", "AXCell", "AXTab", "AXRadioButton"].contains(role),
               Date() < deadline, (axValue(element, kAXSelectedAttribute as String) as? Bool) == true {
                node["selected"] = true
            }
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
        // Visible children keep scrolled-out document text out of the budget.
        let visible = axValue(element, "AXVisibleChildren") as? [AXUIElement]
        if let children = visible, !children.isEmpty {
            pending.append(contentsOf: children.prefix(maxChildren).map { Pending(element: $0, depth: entry.depth + 1, parent: index) })
            if children.count > maxChildren { truncated = true }
        } else if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, maxChildren, &rawChildren) == .success,
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

/// Keep JSON byte content intact while coloring its lexical tokens.
private func highlightedJSON(_ text: String) -> NSAttributedString {
    let result = NSMutableAttributedString(string: text, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ])
    let pattern = #""(?:[^"\\]|\\.)*"\s*:|"(?:[^"\\]|\\.)*"|\b(?:true|false|null)\b|-?\b[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
    let source = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        let token = source.substring(with: match.range)
        let color: NSColor
        if token.hasSuffix(":") { color = .systemBlue }
        else if token.hasPrefix("\"") { color = .systemGreen }
        else if ["true", "false", "null"].contains(token) { color = .systemPurple }
        else { color = .systemOrange }
        result.addAttribute(.foregroundColor, value: color, range: match.range)
    }
    return result
}

private struct CaptureMark {
    let tool: Int
    let color: NSColor
    let stroke: CGFloat
    var points: [NSPoint]
    var text = ""
}

private final class AnnotationCanvas: NSView {
    let image: NSImage
    var marks: [CaptureMark]
    var tool = 0
    var ink: NSColor = .systemRed
    var stroke: CGFloat = 3
    private var draft: CaptureMark?
    private var history = [[CaptureMark]]()
    private let padding: CGFloat

    init(image: NSImage, marks: [CaptureMark], padding: CGFloat = 16) {
        self.padding = padding
        self.image = image; self.marks = marks
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("截图标注画布")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    private var imageRect: NSRect {
        let bounds = bounds.insetBy(dx: padding, dy: padding)
        let scale = min(bounds.width / max(image.size.width, 1), bounds.height / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private func normalized(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        return NSPoint(x: min(1, max(0, (point.x - rect.minX) / max(rect.width, 1))),
                       y: min(1, max(0, (point.y - rect.minY) / max(rect.height, 1))))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        render(in: imageRect, includingDraft: true)
    }
    private func render(in rect: NSRect, includingDraft: Bool) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        image.draw(in: rect)
        for mark in marks + (includingDraft ? draft.map { [$0] } ?? [] : []) {
            let points = mark.points.map { NSPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            guard let first = points.first, let last = points.last else { continue }
            mark.color.setStroke(); mark.color.setFill()
            let width = max(0.5, mark.stroke * rect.width)
            let path = NSBezierPath(); path.lineWidth = width
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            let box = NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            switch mark.tool {
            case 1: path.appendRect(box)
            case 2: path.appendOval(in: box)
            case 3:
                path.move(to: first); path.line(to: last)
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(width * 4, rect.width * 0.016)
                for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    path.move(to: last)
                    path.line(to: NSPoint(x: last.x - cos(angle + offset) * length, y: last.y - sin(angle + offset) * length))
                }
            case 4:
                (mark.text as NSString).draw(at: first, withAttributes: [
                    .font: NSFont.systemFont(ofSize: max(1, mark.stroke * rect.width * 7), weight: .semibold),
                    .foregroundColor: mark.color,
                ])
            default:
                if points.count == 1 {
                    path.appendOval(in: NSRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)); path.fill()
                } else {
                    path.move(to: first)
                    for point in points.dropFirst() { path.line(to: point) }
                }
            }
            if mark.tool != 4 { path.stroke() }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) {
        guard imageRect.contains(convert(event.locationInWindow, from: nil)), marks.count < 500 else { return }
        window?.makeFirstResponder(self)
        var mark = CaptureMark(tool: tool, color: ink, stroke: stroke / max(imageRect.width, 1), points: [normalized(event)])
        if tool == 4 {
            let alert = NSAlert(); alert.messageText = "添加文字"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
            field.placeholderString = "输入标注文字"
            alert.accessoryView = field
            alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
            alert.window.level = window?.level ?? .normal
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            mark.text = String(field.stringValue.prefix(1000))
            history.append(marks); marks.append(mark)
        } else { draft = mark }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard var mark = draft else { return }
        if mark.tool == 0 { mark.points.append(normalized(event)) }
        else { mark.points = [mark.points[0], normalized(event)] }
        draft = mark; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let mark = draft else { return }
        history.append(marks); marks.append(mark); draft = nil; needsDisplay = true
    }
    @objc func undoMark(_ sender: Any?) {
        guard let previous = history.popLast() else {
            if !marks.isEmpty { marks.removeLast(); needsDisplay = true }
            return
        }
        marks = previous; draft = nil; needsDisplay = true
    }
    @objc func clearMarks(_ sender: Any?) {
        guard !marks.isEmpty else { return }
        history.append(marks); marks = []; draft = nil; needsDisplay = true
    }
    func renderedImage() throws -> NSImage {
        let pixelsWide = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
        let pixelsHigh = image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height)
        guard pixelsWide > 0, pixelsHigh > 0, pixelsWide <= 32768, pixelsHigh <= 32768,
              pixelsWide * pixelsHigh <= 100_000_000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "截图过大，无法导出标注图。"])
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        render(in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh), includingDraft: false)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: image.size); result.addRepresentation(bitmap)
        return result
    }
}

private final class AnnotationController: NSWindowController, NSWindowDelegate {
    let canvas: AnnotationCanvas
    var onApply: (([CaptureMark], NSImage?) -> Void)?
    private let tools = NSSegmentedControl(labels: ["画笔", "矩形", "圆圈", "箭头", "文字"], trackingMode: .selectOne, target: nil, action: nil)
    private let colors = NSSegmentedControl(labels: ["红", "橙", "蓝", "绿", "黑", "白"], trackingMode: .selectOne, target: nil, action: nil)
    private let width = NSSlider(value: 3, minValue: 1, maxValue: 10, target: nil, action: nil)

    init(image: NSImage, marks: [CaptureMark]) {
        canvas = AnnotationCanvas(image: image, marks: marks)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "标注截图"; window.minSize = NSSize(width: 800, height: 500)
        super.init(window: window); window.delegate = self
        tools.selectedSegment = 0; tools.target = self; tools.action = #selector(changeTool)
        colors.selectedSegment = 0; colors.target = self; colors.action = #selector(changeColor)
        width.target = self; width.action = #selector(changeWidth); width.setAccessibilityLabel("画笔粗细")
        width.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let undo = NSButton(title: "撤销", target: canvas, action: #selector(AnnotationCanvas.undoMark))
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = .command
        let clear = NSButton(title: "清空", target: canvas, action: #selector(AnnotationCanvas.clearMarks))
        let toolbar = NSStackView(views: [tools, colors, NSTextField(labelWithString: "粗细"), width, undo, clear])
        toolbar.spacing = 10; toolbar.orientation = .horizontal
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEditor))
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        let apply = NSButton(title: "使用标注", target: self, action: #selector(applyMarks))
        apply.keyEquivalent = "\r"; apply.keyEquivalentModifierMask = .command
        for button in [undo, clear, cancel, apply] { button.bezelStyle = .rounded }
        let hint = NSTextField(labelWithString: "拖动绘制 · 选择文字工具后点击添加 · ⌘Z 撤销 · 原图保留")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [hint, NSView(), cancel, apply]); footer.spacing = 10
        guard let content = window.contentView else { return }
        for item in [toolbar, canvas, footer] { item.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(item) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changeTool() { canvas.tool = tools.selectedSegment }
    @objc private func changeColor() { canvas.ink = [NSColor.systemRed, .systemOrange, .systemBlue, .systemGreen, .black, .white][colors.selectedSegment] }
    @objc private func changeWidth() { canvas.stroke = CGFloat(width.doubleValue) }
    @objc func cancelEditor() { if let parent = window?.sheetParent, let window { parent.endSheet(window) }; window?.orderOut(nil) }
    @objc private func applyMarks() {
        do {
            let rendered = canvas.marks.isEmpty ? nil : try canvas.renderedImage()
            onApply?(canvas.marks, rendered)
            cancelEditor()
        } catch {
            let alert = NSAlert(); alert.messageText = "标注图未能导出"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelEditor(); return false }
}

private func captureBitmapImage(_ image: CGImage, logicalSize: NSSize) -> NSImage {
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = logicalSize
    let result = NSImage(size: logicalSize)
    result.addRepresentation(bitmap)
    return result
}

private func capturePixelRect(_ selection: NSRect, viewSize: NSSize, pixelSize: NSSize) -> NSRect {
    guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
    let clipped = selection.intersection(NSRect(origin: .zero, size: viewSize))
    guard !clipped.isNull, !clipped.isEmpty else { return .zero }
    let sx = pixelSize.width / viewSize.width, sy = pixelSize.height / viewSize.height
    let x = floor(clipped.minX * sx), y = floor((viewSize.height - clipped.maxY) * sy)
    return NSRect(x: x, y: y, width: ceil(clipped.maxX * sx) - x,
                  height: ceil((viewSize.height - clipped.minY) * sy) - y)
        .intersection(NSRect(origin: .zero, size: pixelSize))
}

private final class CaptureOverlayWindow: NSWindow {
    var onCancel: (() -> Void)?
    var onComplete: (() -> Void)?
    var onUndo: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { onCancel?(); return }
            if event.keyCode == 36 { onComplete?(); return }
            if event.keyCode == 6 && event.modifierFlags.contains(.command) { onUndo?(); return }
        }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onCancel?(); return true }
        if event.keyCode == 36 { onComplete?(); return true }
        if event.keyCode == 6 && event.modifierFlags.contains(.command) { onUndo?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class CaptureHUDView: NSView {
    var title = ""
    var headerHeight: CGFloat = 32
    private var anchor: NSPoint?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill(); NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        if !title.isEmpty {
            (title as NSString).draw(at: NSPoint(x: 14, y: bounds.height - 24), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ])
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), local.y > bounds.height - headerHeight, local.x < bounds.width - 36 { return self }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { anchor = superview?.convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview, let anchor else { return }
        let point = parent.convert(event.locationInWindow, from: nil)
        var origin = frame.origin
        origin.x = min(parent.bounds.maxX - frame.width, max(0, origin.x + point.x - anchor.x))
        origin.y = min(parent.bounds.maxY - frame.height, max(0, origin.y + point.y - anchor.y))
        setFrameOrigin(origin); self.anchor = point
    }
}

private final class CaptureSelectionView: NSView {
    let snapshot: CGImage
    private let background: NSImage
    private(set) var selection: NSRect?
    private(set) var canvas: AnnotationCanvas?
    var onSelection: ((CaptureSelectionView) -> Void)?
    var selectionTool = true
    private var anchor = NSPoint.zero
    private var previousRect: NSRect?
    private var previousMarks = [CaptureMark]()
    private var operation = 0 // new region, move, resize
    private var edges = [false, false, false, false] // left, right, bottom, top

    init(snapshot: CGImage, size: NSSize) {
        self.snapshot = snapshot
        background = NSImage(cgImage: snapshot, size: size)
        super.init(frame: NSRect(origin: .zero, size: size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("截图选区：拖动框选，选区后可直接标注")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        background.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.42).setFill()
        if let rect = selection, !rect.isEmpty {
            NSRect(x: 0, y: 0, width: bounds.width, height: rect.minY).fill()
            NSRect(x: 0, y: rect.maxY, width: bounds.width, height: bounds.height - rect.maxY).fill()
            NSRect(x: 0, y: rect.minY, width: rect.minX, height: rect.height).fill()
            NSRect(x: rect.maxX, y: rect.minY, width: bounds.width - rect.maxX, height: rect.height).fill()
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1)); border.lineWidth = 2; border.stroke()
            NSColor.white.setFill()
            for point in [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                          NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.midX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
                          NSPoint(x: rect.minX, y: rect.midY), NSPoint(x: rect.maxX, y: rect.midY)] {
                NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
            }
            let pixels = capturePixelRect(rect, viewSize: bounds.size, pixelSize: NSSize(width: snapshot.width, height: snapshot.height))
            let label = "\(Int(pixels.width)) × \(Int(pixels.height))"
            (label as NSString).draw(at: NSPoint(x: rect.minX + 6, y: min(bounds.maxY - 20, rect.maxY + 6)),
                                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        } else { bounds.fill() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        for view in subviews.reversed() where view !== canvas {
            if !view.isHidden, let hit = view.hitTest(point) { return hit }
        }
        if let rect = selection, rect.insetBy(dx: -7, dy: -7).contains(point), !rect.insetBy(dx: 7, dy: 7).contains(point) { return self }
        if selectionTool { return bounds.contains(point) ? self : nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        anchor = convert(event.locationInWindow, from: nil)
        previousRect = selection; previousMarks = canvas?.marks ?? []
        operation = 0
        if let rect = selection, rect.insetBy(dx: -7, dy: -7).contains(anchor) {
            edges = [abs(anchor.x - rect.minX) < 7, abs(anchor.x - rect.maxX) < 7, abs(anchor.y - rect.minY) < 7, abs(anchor.y - rect.maxY) < 7]
            operation = edges.contains(true) ? 2 : 1
        }
        if operation == 0 { selection = NSRect(origin: anchor, size: .zero); previousMarks = [] }
        canvas?.isHidden = true
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        var point = convert(event.locationInWindow, from: nil)
        point.x = min(bounds.maxX, max(0, point.x)); point.y = min(bounds.maxY, max(0, point.y))
        if operation == 1, let old = previousRect {
            selection = NSRect(x: min(bounds.maxX - old.width, max(0, old.minX + point.x - anchor.x)),
                               y: min(bounds.maxY - old.height, max(0, old.minY + point.y - anchor.y)), width: old.width, height: old.height)
        } else if operation == 2, let old = previousRect {
            let x1 = edges[0] ? min(point.x, old.maxX - 8) : old.minX
            let x2 = edges[1] ? max(point.x, old.minX + 8) : old.maxX
            let y1 = edges[2] ? min(point.y, old.maxY - 8) : old.minY
            let y2 = edges[3] ? max(point.y, old.minY + 8) : old.maxY
            selection = NSRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
        } else {
            selection = NSRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let rect = selection, rect.width >= 8, rect.height >= 8, let image = selectedImage() else {
            selection = previousRect; canvas?.isHidden = false; needsDisplay = true; return
        }
        canvas?.removeFromSuperview()
        var marks = previousMarks
        if operation != 0, let old = previousRect {
            marks = marks.map { mark in
                CaptureMark(tool: mark.tool, color: mark.color, stroke: mark.stroke * old.width / rect.width,
                    points: mark.points.map { NSPoint(x: (old.minX + $0.x * old.width - rect.minX) / rect.width,
                                                     y: (old.minY + $0.y * old.height - rect.minY) / rect.height) }, text: mark.text)
            }
        }
        let canvas = AnnotationCanvas(image: image, marks: marks, padding: 0)
        canvas.frame = rect
        addSubview(canvas); self.canvas = canvas
        needsDisplay = true
        onSelection?(self)
    }
    func selectedImage() -> NSImage? {
        guard let rect = selection else { return nil }
        let pixels = capturePixelRect(rect, viewSize: bounds.size, pixelSize: NSSize(width: snapshot.width, height: snapshot.height))
        guard !pixels.isEmpty, let crop = snapshot.cropping(to: pixels) else { return nil }
        return captureBitmapImage(crop, logicalSize: rect.size)
    }
    func discardSelection() {
        canvas?.removeFromSuperview(); canvas = nil; selection = nil; previousRect = nil; previousMarks = []
        needsDisplay = true
    }
}

private final class CaptureOverlayController {
    var onComplete: ((NSImage, [CaptureMark], NSImage?, NSRect?) -> Void)?
    var onCancel: (() -> Void)?
    private var windows = [CaptureOverlayWindow]()
    private var views = [CaptureSelectionView]()
    private var active: CaptureSelectionView?
    private let toolbar = CaptureHUDView(frame: NSRect(x: 0, y: 0, width: 890, height: 46))
    private let infoPanel = CaptureHUDView(frame: NSRect(x: 0, y: 0, width: 330, height: 440))
    private let tools = NSSegmentedControl(labels: ["选区", "画笔", "矩形", "圆圈", "箭头", "文字"], trackingMode: .selectOne, target: nil, action: nil)
    private let colors = NSSegmentedControl(labels: ["红", "橙", "蓝", "绿", "黑", "白"], trackingMode: .selectOne, target: nil, action: nil)
    private let width = NSSlider(value: 3, minValue: 1, maxValue: 10, target: nil, action: nil)
    private let undo = NSButton(title: "撤销", target: nil, action: nil)
    private let clear = NSButton(title: "清空", target: nil, action: nil)
    private let complete = NSButton(title: "完成", target: nil, action: nil)
    private var finishing = false

    init(snapshots: [(NSScreen, CGImage)], context: [String: Any]) {
        for (screen, image) in snapshots {
            let window = CaptureOverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = true; window.backgroundColor = .black
            let view = CaptureSelectionView(snapshot: image, size: screen.frame.size)
            view.onSelection = { [weak self] view in self?.selected(view) }
            window.contentView = view
            window.onCancel = { [weak self] in self?.cancel() }
            window.onComplete = { [weak self] in self?.finish() }
            window.onUndo = { [weak self] in self?.undoMark() }
            windows.append(window); views.append(view)
        }
        toolbar.headerHeight = 0
        toolbar.wantsLayer = true; toolbar.layer?.cornerRadius = 8; toolbar.layer?.masksToBounds = true
        tools.selectedSegment = 0; tools.target = self; tools.action = #selector(changeTool)
        colors.selectedSegment = 0; colors.target = self; colors.action = #selector(changeColor)
        width.target = self; width.action = #selector(changeWidth); width.setAccessibilityLabel("画笔粗细")
        width.widthAnchor.constraint(equalToConstant: 76).isActive = true
        undo.target = self; undo.action = #selector(undoMark); undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = .command
        clear.target = self; clear.action = #selector(clearMarks)
        complete.target = self; complete.action = #selector(finish)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        let ax = NSButton(title: "AX 信息", target: self, action: #selector(toggleInfo))
        for button in [undo, clear, complete, cancel, ax] { button.bezelStyle = .rounded }
        let stack = NSStackView(views: [tools, colors, width, undo, clear, ax, cancel, complete])
        stack.spacing = 8; stack.orientation = .horizontal; stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        do {
            let content = toolbar
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        }
        infoPanel.title = "前景窗口 · AX 信息"
        infoPanel.wantsLayer = true; infoPanel.layer?.cornerRadius = 8; infoPanel.layer?.masksToBounds = true
        let hideInfo = NSButton(title: "×", target: self, action: #selector(toggleInfo))
        hideInfo.frame = NSRect(x: 302, y: 413, width: 20, height: 20)
        hideInfo.bezelStyle = .inline; hideInfo.setAccessibilityLabel("收起 AX 信息")
        infoPanel.addSubview(hideInfo)
        let info = NSTextView(); info.isEditable = false; info.isRichText = false
        info.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        info.textContainerInset = NSSize(width: 14, height: 14)
        info.isVerticallyResizable = true; info.autoresizingMask = [.width]; info.textContainer?.widthTracksTextView = true
        info.setAccessibilityLabel("本次前景窗口无障碍树")
        let app = context["app"] as? [String: Any] ?? [:]
        let window = context["window"] as? [String: Any] ?? [:]
        let axInfo = context["accessibility"] as? [String: Any] ?? [:]
        let nodes = axInfo["nodes"] as? [[String: Any]] ?? []
        var lines = ["按快捷键时的前景窗口快照", "范围可能大于截图选区", "", app["name"] as? String ?? "未知应用",
                     window["title"] as? String ?? "未读取到窗口标题", window["url"] as? String ?? "未读取到页面 URL", "",
                     "AX 状态：\(axInfo["status"] as? String ?? "unavailable") · \(nodes.count) 个节点" + ((axInfo["truncated"] as? Bool == true) ? "（已截断）" : ""), ""]
        if nodes.isEmpty { lines.append("未采集到节点。请核对辅助功能授权与助手菜单中的 AX 开关。") }
        for node in nodes {
            let depth = min(16, node["depth"] as? Int ?? 0)
            let role = node["role"] as? String ?? "AXElement"
            let text = ["title", "text", "description", "url"].compactMap { node[$0] as? String }.filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append(String(repeating: "  ", count: depth) + role + (text.isEmpty ? "" : "  " + text))
        }
        lines.append("\n拖动框选 → 在选区直接标注 → 完成\nEnter 完成 · Escape 取消 · ⌘Z 撤销")
        info.string = lines.joined(separator: "\n")
        let scroll = NSScrollView(); scroll.documentView = info; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.frame = NSRect(x: 1, y: 1, width: 328, height: 406)
        infoPanel.addSubview(scroll)
        setControls(enabled: false)
    }
    private func setControls(enabled: Bool) {
        for index in 1..<tools.segmentCount { tools.setEnabled(enabled, forSegment: index) }
        colors.isEnabled = enabled; width.isEnabled = enabled; undo.isEnabled = enabled; clear.isEnabled = enabled; complete.isEnabled = enabled
    }
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let target = windows.first(where: { $0.screen == screen }) ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        if let view = target?.contentView {
            attachHUDs(to: view)
            infoPanel.setFrameOrigin(NSPoint(x: view.bounds.maxX - 346, y: view.bounds.maxY - 468))
            toolbar.setFrameOrigin(NSPoint(x: max(8, view.bounds.midX - 445), y: 18))
        }
    }
    private func attachHUDs(to view: NSView) {
        toolbar.removeFromSuperview(); infoPanel.removeFromSuperview()
        view.addSubview(toolbar); view.addSubview(infoPanel)
    }
    private func selected(_ view: CaptureSelectionView) {
        for other in views where other !== view { other.discardSelection() }
        active = view; setControls(enabled: true)
        applyTool()
        guard let rect = view.selection else { return }
        let movedScreen = toolbar.superview !== view
        attachHUDs(to: view)
        if movedScreen { infoPanel.setFrameOrigin(NSPoint(x: view.bounds.maxX - 346, y: view.bounds.maxY - 468)) }
        let y = rect.minY - 56 >= 0 ? rect.minY - 56 : min(view.bounds.maxY - 52, rect.maxY + 10)
        toolbar.setFrameOrigin(NSPoint(x: max(8, min(rect.minX, view.bounds.maxX - toolbar.frame.width - 8)), y: y))
    }
    private func applyTool() {
        for view in views { view.selectionTool = tools.selectedSegment == 0 }
        active?.canvas?.tool = max(0, tools.selectedSegment - 1)
        changeColor(); changeWidth()
    }
    @objc private func changeTool() { applyTool(); active?.window?.makeFirstResponder(active?.canvas) }
    @objc private func changeColor() { active?.canvas?.ink = [NSColor.systemRed, .systemOrange, .systemBlue, .systemGreen, .black, .white][colors.selectedSegment] }
    @objc private func changeWidth() { active?.canvas?.stroke = CGFloat(width.doubleValue) }
    @objc private func undoMark() { active?.canvas?.undoMark(nil) }
    @objc private func clearMarks() { active?.canvas?.clearMarks(nil) }
    @objc private func toggleInfo() { infoPanel.isHidden.toggle() }
    @objc func cancel() { guard !finishing else { return }; finishing = true; close(); onCancel?() }
    @objc private func finish() {
        guard !finishing, let view = active, let image = view.selectedImage(), let canvas = view.canvas else { return }
        do {
            let annotated = canvas.marks.isEmpty ? nil : try canvas.renderedImage()
            let region = view.selection.flatMap { rect -> NSRect? in
                guard let screen = view.window?.screen,
                      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return captureScreenRegion(rect, viewSize: view.bounds.size, display: CGDisplayBounds(number.uint32Value))
            }
            finishing = true; close(); onComplete?(image, canvas.marks, annotated, region)
        } catch {
            let alert = NSAlert(); alert.messageText = "截图未能导出"; alert.informativeText = error.localizedDescription
            alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 4); alert.runModal()
        }
    }
    func close() { toolbar.removeFromSuperview(); infoPanel.removeFromSuperview(); for window in windows { window.orderOut(nil); window.close() } }
}

private func captureScreenRegion(_ rect: NSRect, viewSize: NSSize, display: NSRect) -> NSRect {
    let xScale = display.width / viewSize.width
    let yScale = display.height / viewSize.height
    return NSRect(x: display.minX + rect.minX * xScale,
                  y: display.minY + (viewSize.height - rect.maxY) * yScale,
                  width: rect.width * xScale, height: rect.height * yScale)
}

@available(macOS 14.0, *)
@MainActor
private final class DisplaySnapshotReader {
    private var screens = [NSScreen]()
    private var displays = [SCDisplay]()
    private var snapshots = [(NSScreen, CGImage)]()
    private let completion: (Result<[(NSScreen, CGImage)], Error>) -> Void

    init(completion: @escaping (Result<[(NSScreen, CGImage)], Error>) -> Void) { self.completion = completion }

    func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let content else {
                    self.completion(.failure(error ?? NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取显示器列表。"])))
                    return
                }
                self.screens = NSScreen.screens
                self.displays = content.displays
                self.next(0)
            }
        }
    }
    private func next(_ index: Int) {
        if index >= screens.count { completion(.success(snapshots)); return }
        let screen = screens[index]
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = displays.first(where: { $0.displayID == id }) else {
            completion(.failure(NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "显示器已断开，请重新截图。"])))
            return
        }
        let config = SCStreamConfiguration()
        // Quartz display dimensions may be logical points; retain backing pixels.
        config.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        config.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        config.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config) { image, error in
            DispatchQueue.main.async {
                guard let image else {
                    self.completion(.failure(error ?? NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "读取屏幕图像失败。"])))
                    return
                }
                // Only the main actor owns AppKit objects and mutable results;
                // platform callbacks capture this actor reference and an index.
                self.snapshots.append((self.screens[index], image))
                self.next(index + 1)
            }
        }
    }
}

@available(macOS 14.0, *)
private func captureDisplaySnapshots(_ completion: @escaping (Result<[(NSScreen, CGImage)], Error>) -> Void) {
    DispatchQueue.main.async { DisplaySnapshotReader(completion: completion).start() }
}

private final class CaptureInputController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onSubmit: ((String, Bool) -> Void)?
    var onCancel: (() -> Void)?
    private let textView = NSTextView()
    private let preview = NSImageView()
    private var originalImage: NSImage
    private var marks = [CaptureMark]()
    private var annotatedImage: NSImage?
    private var annotationEditor: AnnotationController?
    private let annotateButton = NSButton(title: "标注截图…", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let statusIcon = NSImageView()
    private let projectLabel = NSTextField(labelWithString: RecognitionProgress.identifying.title)
    private let detailLabel = NSTextField(wrappingLabelWithString: RecognitionProgress.identifying.detail)
    private let submissionHint = "⌘ Return 快捷完成 · Return 换行\n开始会话会直接打开 Codex，跳过预设跟进"
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "快捷完成", target: nil, action: nil)
    private let conversationButton = NSButton(title: "开始会话", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let debugButton = NSButton(title: "Luna 调试 ▸", target: nil, action: nil)
    private let debugPanel = NSView()
    private let requestText = NSTextView()
    private let responseText = NSTextView()
    private var debugWidth: NSLayoutConstraint!
    private var debugBodyWidth: NSLayoutConstraint!
    private var debugSnapshot: Data?
    private var debugExpanded = false
    private var progress = RecognitionProgress.identifying
    private var submitting = false
    private var cancellable = true
    private var dismissed = false

    init(image: NSImage) {
        originalImage = image
        let window = CaptureInputWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Capture"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        window.onEscape = { [weak self] in self?.cancelInput(nil) }
        window.onSubmit = { [weak self] in self?.submitInput(nil) }

        let root = NSView()
        window.contentView = root
        let content = NSView()
        let debugContainer = NSView()
        debugContainer.wantsLayer = true
        debugContainer.layer?.masksToBounds = true
        debugPanel.translatesAutoresizingMaskIntoConstraints = false
        debugContainer.addSubview(debugPanel)
        for item in [content, debugContainer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        debugWidth = debugContainer.widthAnchor.constraint(equalToConstant: 0)
        debugBodyWidth = debugPanel.widthAnchor.constraint(equalToConstant: 480)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.trailingAnchor.constraint(equalTo: debugContainer.leadingAnchor),
            debugContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            debugContainer.topAnchor.constraint(equalTo: root.topAnchor),
            debugContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            debugPanel.leadingAnchor.constraint(equalTo: debugContainer.leadingAnchor),
            debugPanel.topAnchor.constraint(equalTo: debugContainer.topAnchor),
            debugPanel.bottomAnchor.constraint(equalTo: debugContainer.bottomAnchor),
            debugWidth, debugBodyWidth,
        ])
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
        messageLabel.stringValue = submissionHint
        startButton.bezelStyle = .rounded
        startButton.target = self; startButton.action = #selector(submitInput)
        startButton.keyEquivalent = "\r"; startButton.keyEquivalentModifierMask = .command
        conversationButton.bezelStyle = .rounded
        conversationButton.target = self; conversationButton.action = #selector(submitInput)
        conversationButton.toolTip = "直接打开 Codex 会话，跳过预设跟进"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self; cancelButton.action = #selector(cancelInput)
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        let buttons = NSStackView(views: [cancelButton, conversationButton, startButton])
        buttons.orientation = .horizontal; buttons.spacing = 8

        debugButton.bezelStyle = .inline
        debugButton.target = self; debugButton.action = #selector(toggleDebug)
        let debugTitle = NSTextField(labelWithString: "Luna")
        debugTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let divider = NSBox(); divider.boxType = .separator
        let requestLabel = NSTextField(labelWithString: "Request body")
        let responseLabel = NSTextField(labelWithString: "Response body")
        for label in [requestLabel, responseLabel] {
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        func codeView(_ text: NSTextView, label: String) -> NSScrollView {
            text.isEditable = false; text.isRichText = false
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textContainerInset = NSSize(width: 12, height: 10)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.string = label == "Request body" ? "等待请求…" : "等待响应…"
            text.setAccessibilityLabel(label)
            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 7
            scroll.layer?.masksToBounds = true
            return scroll
        }
        let requestScroll = codeView(requestText, label: "Request body")
        let responseScroll = codeView(responseText, label: "Response body")
        debugPanel.isHidden = true
        for item in [divider, debugTitle, requestLabel, requestScroll, responseLabel, responseScroll] {
            item.translatesAutoresizingMaskIntoConstraints = false
            debugPanel.addSubview(item)
        }
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: debugPanel.leadingAnchor),
            divider.topAnchor.constraint(equalTo: debugPanel.topAnchor, constant: 18),
            divider.bottomAnchor.constraint(equalTo: debugPanel.bottomAnchor, constant: -18),
            divider.widthAnchor.constraint(equalToConstant: 1),
            debugTitle.topAnchor.constraint(equalTo: debugPanel.topAnchor, constant: 20),
            debugTitle.leadingAnchor.constraint(equalTo: debugPanel.leadingAnchor, constant: 20),
            requestLabel.topAnchor.constraint(equalTo: debugTitle.bottomAnchor, constant: 16),
            requestLabel.leadingAnchor.constraint(equalTo: debugTitle.leadingAnchor),
            requestScroll.topAnchor.constraint(equalTo: requestLabel.bottomAnchor, constant: 7),
            requestScroll.leadingAnchor.constraint(equalTo: debugTitle.leadingAnchor),
            requestScroll.trailingAnchor.constraint(equalTo: debugPanel.trailingAnchor, constant: -20),
            responseLabel.topAnchor.constraint(equalTo: requestScroll.bottomAnchor, constant: 16),
            responseLabel.leadingAnchor.constraint(equalTo: debugTitle.leadingAnchor),
            responseScroll.topAnchor.constraint(equalTo: responseLabel.bottomAnchor, constant: 7),
            responseScroll.leadingAnchor.constraint(equalTo: debugTitle.leadingAnchor),
            responseScroll.trailingAnchor.constraint(equalTo: requestScroll.trailingAnchor),
            responseScroll.bottomAnchor.constraint(equalTo: debugPanel.bottomAnchor, constant: -20),
            requestScroll.heightAnchor.constraint(equalTo: responseScroll.heightAnchor),
        ])
        for item in [preview, recognition, heading, editor, messageLabel, debugButton, buttons] {
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
            debugButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 2),
            debugButton.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
        annotateButton.bezelStyle = .rounded
        annotateButton.target = self; annotateButton.action = #selector(editAnnotation)
        annotateButton.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(annotateButton)
        NSLayoutConstraint.activate([
            annotateButton.topAnchor.constraint(equalTo: preview.topAnchor, constant: 8),
            annotateButton.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -8),
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
        window?.orderFrontRegardless()
        window?.makeFirstResponder(textView)
    }

    @objc private func toggleDebug() {
        debugExpanded.toggle()
        debugButton.title = debugExpanded ? "Luna 调试 ▾" : "Luna 调试 ▸"
        debugPanel.isHidden = !debugExpanded
        guard let window else { return }
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let sidebarWidth = min(480, max(300, screen.width - 620))
        debugBodyWidth.constant = sidebarWidth
        debugWidth.constant = debugExpanded ? sidebarWidth : 0
        var frame = window.frame
        frame.size.width = 620 + debugWidth.constant
        frame.origin.x = min(frame.origin.x, screen.maxX - frame.width)
        frame.origin.x = max(screen.minX, frame.origin.x)
        window.setFrame(frame, display: true)
    }

    func updateDebug(directory: URL) {
        let url = directory.appendingPathComponent("classification-debug.json")
        guard let data = try? Data(contentsOf: url), data.count <= 4_194_304, data != debugSnapshot,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        debugSnapshot = data
        updateDebugBodies(object)
    }

    func updateDebugBodies(_ object: [String: Any]) {
        var request: [String: Any] = [:]
        var response: [String: Any] = [:]
        request["thread/start"] = object["threadRequest"]
        request["turn/start"] = object["turnRequest"]
        response["thread/start"] = object["threadResponse"]
        response["turn/completed"] = object["turnResponse"]
        response["error"] = object["error"]
        for (textView, body) in [(requestText, request), (responseText, response)] {
            guard !body.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8), text != textView.string else { continue }
            let selection = textView.selectedRange()
            let origin = textView.enclosingScrollView?.contentView.bounds.origin
            textView.textStorage?.setAttributedString(highlightedJSON(text))
            textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count), length: 0))
            if let origin, let scroll = textView.enclosingScrollView {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    @objc private func editAnnotation() {
        guard !submitting, let window, window.attachedSheet == nil else { return }
        let editor = AnnotationController(image: originalImage, marks: marks)
        editor.onApply = { [weak self] marks, image in
            guard let self else { return }
            self.applyAnnotations(marks, image: image)
        }
        annotationEditor = editor
        if let sheet = editor.window { window.beginSheet(sheet) }
    }

    func applyAnnotations(_ marks: [CaptureMark], image: NSImage?) {
        self.marks = marks; self.annotatedImage = image
        preview.image = image ?? originalImage
        annotateButton.title = marks.isEmpty ? "标注截图…" : "已标注 · 编辑…"
    }

    func closeAnnotationEditor() { annotationEditor?.cancelEditor(); annotationEditor = nil }

    func writeAnnotatedImage(to url: URL) throws -> Bool {
        guard let annotatedImage, let bitmap = annotatedImage.representations.first as? NSBitmapImageRep,
              let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    func replaceScreenshot(_ image: NSImage) {
        closeAnnotationEditor()
        originalImage = image; annotatedImage = nil; marks = []
        annotateButton.title = "标注截图…"
        preview.image = image
        debugSnapshot = nil
        requestText.string = "等待请求…"
        responseText.string = "等待响应…"
        setSubmitting(false)
        updateRecognition(.identifying)
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

    func setSubmitting(_ value: Bool, awaitingPreparation: Bool = false, startConversation: Bool = false) {
        submitting = value
        annotateButton.isEnabled = !value
        cancellable = !value || awaitingPreparation
        let status = startConversation ? "正在打开 Codex 会话…" : "正在提交后台任务…"
        messageLabel.stringValue = value ? (awaitingPreparation ? "正在准备项目识别…" : status) : submissionHint
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
        closeAnnotationEditor()
        dismissed = true
        window?.orderOut(nil)
        close()
    }

    private func refreshControls() {
        startButton.isEnabled = !submitting && !progress.failed && validDescription(textView.string)
        conversationButton.isEnabled = startButton.isEnabled
        cancelButton.isEnabled = cancellable
        window?.standardWindowButton(.closeButton)?.isEnabled = cancellable
        textView.isEditable = !submitting
    }

    func textDidChange(_ notification: Notification) {
        if !submitting {
            messageLabel.stringValue = textView.string.count > 5_000 ? "描述请控制在 5000 字以内。" : submissionHint
            messageLabel.textColor = textView.string.count > 5_000 ? .systemRed : .secondaryLabelColor
        }
        refreshControls()
    }

    @objc private func submitInput(_ sender: Any?) {
        guard !submitting, !progress.failed, validDescription(textView.string) else { return }
        onSubmit?(textView.string, (sender as? NSButton) === conversationButton)
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
    var startConversation = false
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
    private var captureOverlay: CaptureOverlayController?
    private var selectingScreenshot = false
    private let startedAt = timestamp()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: appID).contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if duplicate { NSApp.terminate(nil); return }
        UserDefaults.standard.register(defaults: [axPreference: true])
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
        captureOverlay?.close()
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
        capture.target = self; capture.isEnabled = !busy || canReplaceCapture
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

    private var canReplaceCapture: Bool {
        !selectingScreenshot && state == "awaiting_description" && inputSession != nil && inputSession?.submissionInFlight == false
    }

    fileprivate func beginCapture() {
        guard !selectingScreenshot, !busy || canReplaceCapture else { return }
        if let lastTrigger, Date().timeIntervalSince(lastTrigger) < 0.4 { return }
        lastTrigger = Date(); lastError = nil
        guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
            alert("尚未安装任务入口", "请重新运行插件的 install.sh。\n" + launcherURL.path); return
        }
        selectingScreenshot = true
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
        inputSession?.controller.closeAnnotationEditor()
        inputSession?.controller.window?.orderOut(nil)
        if #available(macOS 14.0, *) {
            captureDisplaySnapshots { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): self.fail(error, temporary: temporary)
                case .success(let snapshots):
                    guard !snapshots.isEmpty else {
                        self.fail(NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的显示器。"]), temporary: temporary)
                        return
                    }
                    let overlay = CaptureOverlayController(snapshots: snapshots, context: context)
                    self.captureOverlay = overlay
                    overlay.onCancel = { [weak self] in
                        guard let self else { return }
                        self.captureOverlay = nil; self.state = "ready"; self.finishCapture(temporary: temporary)
                        if self.inputSession == nil { _ = source?.activate(options: []) }
                    }
                    overlay.onComplete = { [weak self] image, marks, annotated, region in
                        guard let self else { return }
                        self.captureOverlay = nil
                        do {
                            guard let bitmap = image.representations.first as? NSBitmapImageRep,
                                  let data = bitmap.representation(using: .png, properties: [:]) else {
                                throw NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "无法保存截图。"])
                            }
                            try data.write(to: screenshot, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: screenshot.path)
                            var evidence = context
                            if let region, let bounds = context["windowBounds"] as? [CGFloat], bounds.count == 4 {
                                let window = NSRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3])
                                evidence["foregroundOverlap"] = window.contains(region) ? "inside" : (window.intersects(region) ? "partial" : "outside")
                            }
                            self.askDescription(screenshot: screenshot, context: evidence, temporary: temporary, marks: marks, annotated: annotated)
                        } catch { self.fail(error, temporary: temporary) }
                    }
                    overlay.present()
                }
            }
            return
        }
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

    private func askDescription(screenshot: URL, context: [String: Any], temporary: URL, marks: [CaptureMark] = [], annotated: NSImage? = nil) {
        selectingScreenshot = false
        guard let image = NSImage(contentsOf: screenshot) else {
            fail(NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取本次截图，请重新截图。"]), temporary: temporary)
            return
        }
        let contextFile = temporary.appendingPathComponent("context.json")
        var evidence = context
        evidence.removeValue(forKey: "windowBounds")
        do { try writeJSON(evidence, to: contextFile) }
        catch { fail(error, temporary: temporary); return }
        let controller: CaptureInputController
        if let previous = inputSession {
            controller = previous.controller
            cancelInputSession(previous, dismissWindow: false)
            controller.replaceScreenshot(image)
        } else {
            controller = CaptureInputController(image: image)
        }
        controller.applyAnnotations(marks, image: annotated)
        let session = CaptureInputSession(controller: controller, temporary: temporary)
        inputSession = session
        controller.onSubmit = { [weak self, weak session] text, startConversation in
            guard let self, let session, self.inputSession === session else { return }
            session.pendingDescription = text
            session.startConversation = startConversation
            session.controller.setSubmitting(true, awaitingPreparation: session.preparationID == nil, startConversation: startConversation)
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
        func readRecord() -> [String: Any]? {
            guard let info = try? stateURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  info.isSymbolicLink != true, let size = info.fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: stateURL),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return record
        }
        guard let record = readRecord() else {
            if Date().timeIntervalSince(session.startedAt) > 30 {
                preparationFailed(session, message: "无法读取项目识别状态，请取消后重新截图。")
            }
            return
        }
        session.controller.updateDebug(directory: stateURL.deletingLastPathComponent())
        var progress = RecognitionProgress(state: record)
        if progress.loading, let pid = record["workerPid"] as? Int ?? session.preparationWorkerPID,
           pid <= 1 || pid > Int(Int32.max) || kill(pid_t(pid), 0) != 0 {
            // The worker writes its terminal state before exiting. Refresh the
            // earlier loading snapshot before deciding that recognition failed.
            if let latest = readRecord() { progress = RecognitionProgress(state: latest) }
            if progress.loading {
                preparationFailed(session, message: "项目识别进程已退出，请取消后重新截图。")
                return
            }
        }
        session.controller.updateRecognition(progress)
        if !progress.loading {
            session.preparationFinished = true
            session.pollTimer?.invalidate(); session.pollTimer = nil
            if progress.failed && !session.submissionInFlight {
                session.pendingDescription = nil
                session.controller.setSubmitting(false)
                lastError = progress.detail; state = "awaiting_description"; writeStatus()
            }
        } else if record["workerPid"] == nil && session.preparationWorkerPID == nil && Date().timeIntervalSince(session.startedAt) > 10 {
            preparationFailed(session, message: "项目识别进程未能启动，请取消后重新截图。")
        } else if Date().timeIntervalSince(session.startedAt) > 300 {
            preparationFailed(session, message: "项目识别等待超时，请取消后重新截图。")
        }
    }

    private func submitPreparedSession(_ session: CaptureInputSession) {
        guard inputSession === session, !session.cancelled, !session.submissionInFlight,
              let preparationID = session.preparationID, let text = session.pendingDescription else { return }
        let annotatedURL = session.temporary.appendingPathComponent("annotated.png")
        let annotationPath: String?
        do { annotationPath = try session.controller.writeAnnotatedImage(to: annotatedURL) ? annotatedURL.path : nil }
        catch {
            session.pendingDescription = nil
            session.controller.showSubmissionError("无法保存标注图。" + error.localizedDescription)
            state = "awaiting_description"; writeStatus()
            return
        }
        session.submissionInFlight = true
        session.pollTimer?.invalidate(); session.pollTimer = nil
        let startConversation = session.startConversation
        session.controller.setSubmitting(true, startConversation: startConversation)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try command(launcherURL.path, submissionArguments(preparationID: preparationID, text: text, annotatedImage: annotationPath, startConversation: startConversation), timeout: 30)
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
                    self.item.button?.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: startConversation ? "会话已提交" : "任务已提交")
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

    private func cancelInputSession(_ session: CaptureInputSession, dismissWindow: Bool = true) {
        guard inputSession === session, !session.submissionInFlight else { return }
        session.cancelled = true
        session.pollTimer?.invalidate(); session.pollTimer = nil
        if dismissWindow { session.controller.dismiss() }
        if let preparationID = session.preparationID { discardPreparation(preparationID) }
        inputSession = nil
        state = "ready"
        // prepare may still be copying these inputs. Its completion callback
        // owns cleanup until the command has returned, even after this closes.
        if dismissWindow {
            finishCapture(temporary: session.preparationReturned ? session.temporary : nil)
        } else if session.preparationReturned {
            try? FileManager.default.removeItem(at: session.temporary)
        }
    }

    private func fail(_ error: Error, temporary: URL?) {
        lastError = error.localizedDescription; state = "error"
        alert("Codex Capture 未能开始任务", error.localizedDescription)
        finishCapture(temporary: temporary)
    }
    private func finishCapture(temporary: URL? = nil) {
        selectingScreenshot = false
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        if let inputSession {
            state = "awaiting_description"
            busy = true
            inputSession.controller.present()
        } else {
            busy = false
        }
        refreshMenu(); writeStatus()
    }
}

/// Synthetic content for local visual QA. This mode never initializes the
/// menu-bar delegate, reads another application, or invokes a model/launcher.
private final class CapturePreviewDelegate: NSObject, NSApplicationDelegate {
    private var controller: CaptureInputController?
    private var overlay: CaptureOverlayController?

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
        if CommandLine.arguments.contains("--preview-capture"), let screen = NSScreen.main,
           let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let context: [String: Any] = [
                "app": ["name": "Demo Browser"],
                "window": ["title": "Demo Notes · 合成截图", "url": "https://demo.invalid/#/notes/fixture"],
                "accessibility": ["status": "captured", "nodes": [
                    ["role": "AXWindow", "depth": 0, "title": "Demo Notes"],
                    ["role": "AXWebArea", "depth": 1, "url": "https://demo.invalid/#/notes/fixture"],
                    ["role": "AXHeading", "depth": 2, "title": "旅行清单"],
                    ["role": "AXStaticText", "depth": 2, "text": "确认车票和住宿"],
                ]],
            ]
            let overlay = CaptureOverlayController(snapshots: [(screen, bitmap)], context: context)
            self.overlay = overlay
            overlay.onCancel = { NSApp.terminate(nil) }
            overlay.onComplete = { [weak self] image, marks, annotated, _ in
                let controller = CaptureInputController(image: image)
                controller.applyAnnotations(marks, image: annotated)
                self?.controller = controller; self?.overlay = nil
                controller.onCancel = { controller.dismiss(); NSApp.terminate(nil) }
                controller.onSubmit = { _, _ in controller.showSubmissionError("这是界面预览，不会创建任务。") }
                controller.updateRecognition(RecognitionProgress(state: ["phase": "ready", "project": ["name": "Demo Notes"]]))
                controller.present()
            }
            overlay.present()
            return
        }
        let controller = CaptureInputController(image: image)
        self.controller = controller
        controller.updateDebugBodies([
            "threadRequest": ["model": "gpt-6-luna", "ephemeral": true, "sandbox": "read-only"],
            "turnRequest": ["input": [["type": "text", "text": "识别 Demo Notes 截图所属项目。"],
                                      ["type": "localImage", "path": "/tmp/synthetic-preview.png"]], "effort": "low"],
            "turnResponse": ["status": "completed", "elapsedSeconds": 1.25,
                             "finalText": "{\"projectId\":\"demo-notes\",\"confidence\":0.99}"],
        ])
        controller.onCancel = { controller.dismiss(); NSApp.terminate(nil) }
        controller.onSubmit = { _, _ in controller.showSubmissionError("这是界面预览，不会创建任务。") }
        controller.present()
        if !CommandLine.arguments.contains("--preview-loading") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.controller?.updateRecognition(RecognitionProgress(state: ["phase": "ready", "project": ["name": "Demo Notes"]]))
            }
        }
    }
}

if CommandLine.arguments.contains("--probe-screens") {
    if #available(macOS 14.0, *) {
        _ = NSApplication.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            fputs("Screen snapshot diagnostic timed out.\n", stderr); exit(1)
        }
        captureDisplaySnapshots { result in
            switch result {
            case .success(let images):
                let summary = images.map { screen, image in ["pixelsWide": image.width, "pixelsHigh": image.height,
                                                            "logicalWidth": Int(screen.frame.width), "logicalHeight": Int(screen.frame.height)] }
                if let data = try? JSONSerialization.data(withJSONObject: ["snapshots": summary], options: [.sortedKeys]) {
                    print(String(data: data, encoding: .utf8)!)
                }
                exit(images.isEmpty ? 1 : 0)
            case .failure(let error): fputs((error.localizedDescription + "\n"), stderr); exit(1)
            }
        }
        RunLoop.main.run()
    } else { fputs("Screen snapshot diagnostic requires macOS 14.\n", stderr); exit(2) }
} else if let flag = CommandLine.arguments.firstIndex(of: "--probe-context") {
    guard CommandLine.arguments.indices.contains(flag + 1) else {
        fputs("Usage: CodexCapture --probe-context <application-bundle-id>\n", stderr)
        exit(2)
    }
    let bundleID = CommandLine.arguments[flag + 1]
    guard let source = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        fputs("Requested application is not running.\n", stderr)
        exit(2)
    }
    // Exercise the exact screenshot-time reader without opening a window,
    // capturing pixels, requesting permission, or invoking a model.
    let context = foregroundContext(source, includeAX: true)
    let data = try JSONSerialization.data(withJSONObject: context, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else if CommandLine.arguments.contains("--self-test") {
    precondition(capturePixelRect(NSRect(x: 10, y: 20, width: 30, height: 40), viewSize: NSSize(width: 100, height: 100), pixelSize: NSSize(width: 200, height: 200)) == NSRect(x: 20, y: 80, width: 60, height: 80))
    precondition(capturePixelRect(NSRect(x: -10, y: -10, width: 30, height: 30), viewSize: NSSize(width: 100, height: 100), pixelSize: NSSize(width: 200, height: 200)) == NSRect(x: 0, y: 160, width: 40, height: 40))
    precondition(capturePixelRect(NSRect(x: 120, y: 120, width: 10, height: 10), viewSize: NSSize(width: 100, height: 100), pixelSize: NSSize(width: 200, height: 200)).isEmpty)
    // Bitmap-only fixture: verify annotation export dimensions, actual painted
    // pixels, original preservation, and undo when reopening saved marks.
    let sourceBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0..<64 { for y in 0..<32 { sourceBitmap.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), atX: x, y: y) } }
    let sourceImage = NSImage(size: NSSize(width: 64, height: 32)); sourceImage.addRepresentation(sourceBitmap)
    let cropPixels = capturePixelRect(NSRect(x: 8, y: 4, width: 24, height: 16), viewSize: sourceImage.size, pixelSize: NSSize(width: 64, height: 32))
    let cropImage = captureBitmapImage(sourceBitmap.cgImage!.cropping(to: cropPixels)!, logicalSize: NSSize(width: 24, height: 16))
    precondition(cropImage.representations.first is NSBitmapImageRep)
    let cropBitmap = cropImage.representations.first as! NSBitmapImageRep
    precondition(cropBitmap.pixelsWide == 24 && cropBitmap.pixelsHigh == 16)
    precondition(cropBitmap.representation(using: .png, properties: [:]) != nil)
    let fixtureMark = CaptureMark(tool: 1, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), stroke: 0.04, points: [NSPoint(x: 0.1, y: 0.2), NSPoint(x: 0.9, y: 0.8)])
    let fixtureCanvas = AnnotationCanvas(image: sourceImage, marks: [fixtureMark])
    let rendered = try fixtureCanvas.renderedImage()
    let outputBitmap = rendered.representations[0] as! NSBitmapImageRep
    let png = outputBitmap.representation(using: .png, properties: [:])!
    let decoded = NSBitmapImageRep(data: png)!
    precondition(decoded.pixelsWide == 64 && decoded.pixelsHigh == 32)
    let painted = decoded.colorAt(x: 6, y: 16)!.usingColorSpace(.deviceRGB)!
    precondition(painted.redComponent > 0.8 && painted.greenComponent < 0.2)
    precondition(sourceBitmap.colorAt(x: 6, y: 16)!.usingColorSpace(.deviceRGB)!.greenComponent > 0.9)
    fixtureCanvas.undoMark(nil); precondition(fixtureCanvas.marks.isEmpty)
    fixtureCanvas.marks = [fixtureMark]; fixtureCanvas.clearMarks(nil); precondition(fixtureCanvas.marks.isEmpty)
    fixtureCanvas.undoMark(nil); precondition(fixtureCanvas.marks.count == 1)
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
    precondition(submissionArguments(preparationID: "fixture", text: originalDescription, annotatedImage: "annotated.png", startConversation: true) ==
        ["submit", "--preparation-id", "fixture", "--text=" + originalDescription, "--annotated-image", "annotated.png", "--start-conversation"])
    precondition(validDescription(originalDescription))
    precondition(!validDescription("  \n "))
    precondition(validDescription(String(repeating: "字", count: 5_000)))
    precondition(!validDescription(String(repeating: "字", count: 5_001)))
    precondition(captureScreenRegion(NSRect(x: 10, y: 20, width: 30, height: 40),
                                    viewSize: NSSize(width: 100, height: 100),
                                    display: NSRect(x: -200, y: 100, width: 200, height: 200))
                 == NSRect(x: -180, y: 180, width: 60, height: 80))
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
    precondition(safeURL("https://user:password@example.com/?token=secret#/daily/fixture?token=secret") == "https://example.com/#/daily/fixture")
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
} else if CommandLine.arguments.contains("--preview-input") || CommandLine.arguments.contains("--preview-capture") {
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
