import Cocoa
import Darwin
import WebKit

private let appName = "DeepSeek Harness"
private let readinessPrefix = "dsh web: "
private let marketEntryID = "dsh-market"

private func failure(_ code: Int, _ message: String) -> NSError {
    NSError(domain: appName, code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

private func readinessURL(from line: String) -> URL? {
    guard line.hasPrefix(readinessPrefix) else { return nil }
    let value = line.dropFirst(readinessPrefix.count).split(separator: " ", maxSplits: 1)[0]
    guard let url = URL(string: String(value)), url.scheme == "http", url.host == "127.0.0.1" else { return nil }
    return url
}

private func containsMarketEntry(_ config: String) -> Bool {
    for line in config.split(whereSeparator: \.isNewline) {
        guard line.hasPrefix("- id:") else { continue }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var value = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        if value == marketEntryID { return true }
    }
    return false
}

private struct HarnessResources {
    let root: URL
    let node: URL
    let launcher: URL
    let marketPatch: URL
    let marketConflictPatch: URL
    let recoveryScript: URL
    let diagnosisScript: URL

    static func load() throws -> HarnessResources {
        guard let root = Bundle.main.resourceURL else { throw failure(1, "应用资源目录不可用。") }
        let resources = HarnessResources(
            root: root,
            node: root.appendingPathComponent("node/bin/node"),
            launcher: root.appendingPathComponent("runtime/lib/bin.js"),
            marketPatch: root.appendingPathComponent("desktop/market.patch.yml"),
            marketConflictPatch: root.appendingPathComponent("desktop/market-conflict.patch.yml"),
            recoveryScript: root.appendingPathComponent("desktop/reset-web-profile.mjs"),
            diagnosisScript: root.appendingPathComponent("desktop/diagnose-web-plugins.mjs")
        )
        guard FileManager.default.isExecutableFile(atPath: resources.node.path) else {
            throw failure(2, "内置 Node.js 运行时缺失。")
        }
        guard FileManager.default.fileExists(atPath: resources.launcher.path) else {
            throw failure(3, "DeepSeek Harness 运行时缺失。")
        }
        for patch in [resources.marketPatch, resources.marketConflictPatch] {
            guard FileManager.default.fileExists(atPath: patch.path) else {
                throw failure(4, "内置插件市场配置缺失。")
            }
        }
        guard FileManager.default.fileExists(atPath: resources.recoveryScript.path) else {
            throw failure(7, "本地环境恢复工具缺失。")
        }
        guard FileManager.default.fileExists(atPath: resources.diagnosisScript.path) else {
            throw failure(10, "启动诊断工具缺失。")
        }
        return resources
    }

    func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = node.deletingLastPathComponent().path + ":" + inheritedPath
        return environment
    }
}

private enum MarketLaunchMode {
    case local
    case bundled
    case bundledReplacingLocal

    func arguments(resources: HarnessResources) -> [String] {
        var arguments = [resources.launcher.path, "web"]
        switch self {
        case .local:
            break
        case .bundled:
            arguments += ["--patch", resources.marketPatch.path]
        case .bundledReplacingLocal:
            arguments += ["--patch", resources.marketConflictPatch.path]
        }
        arguments += ["--port", "0"]
        return arguments
    }
}

private struct CommandOutcome {
    let status: Int32
    let stdout: String
    let stderr: String
}

/** Runs one short bundled-Node command with both pipes drained concurrently. */
private final class CapturedCommand {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var outputBuffer = Data()
    private var errorBuffer = Data()

    func run(resources: HarnessResources, arguments: [String], input: Data? = nil, timeout: TimeInterval) throws -> CommandOutcome {
        process.executableURL = resources.node
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = resources.environment()
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] in self?.consumeOutput($0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { [weak self] in self?.consumeError($0.availableData) }
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            do {
                try stdin.fileHandleForWriting.write(contentsOf: input)
                try stdin.fileHandleForWriting.close()
            } catch {
                process.terminate()
                process.waitUntilExit()
                throw error
            }
        } else {
            try process.run()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(4)
            while process.isRunning && Date() < killDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            closePipes()
            let detail = lock.withLock { String(data: errorBuffer, encoding: .utf8) ?? "" }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(11, "内置命令执行超时（\(arguments.joined(separator: " "))）。" + (detail.isEmpty ? "" : "\n\n\(detail)"))
        }
        process.waitUntilExit()
        consumeOutput(output.fileHandleForReading.readDataToEndOfFile())
        consumeError(errors.fileHandleForReading.readDataToEndOfFile())
        closePipes()
        let state = lock.withLock { (String(data: outputBuffer, encoding: .utf8) ?? "", String(data: errorBuffer, encoding: .utf8) ?? "") }
        return CommandOutcome(status: process.terminationStatus, stdout: state.0, stderr: state.1)
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { outputBuffer.append(data) }
    }

    private func consumeError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { errorBuffer.append(data) }
    }

    private func closePipes() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }
}

private func detectsLocalMarket(resources: HarnessResources) throws -> Bool {
    let outcome = try CapturedCommand().run(
        resources: resources,
        arguments: [resources.launcher.path, "web", "--dump-config"],
        timeout: 60
    )
    guard outcome.status == 0 else {
        let detail = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "无法检查本地插件配置（状态码 \(outcome.status)）。" + (detail.isEmpty ? "" : "\n\n\(detail)")
        throw failure(5, message)
    }
    return containsMarketEntry(outcome.stdout)
}

private struct ProfileRecoveryResult: Decodable {
    let changed: Bool
    let backup: String?
}

private func resetWebProfile(resources: HarnessResources) throws -> ProfileRecoveryResult {
    let outcome = try CapturedCommand().run(
        resources: resources,
        arguments: [resources.recoveryScript.path],
        timeout: 60
    )
    guard outcome.status == 0 else {
        let detail = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw failure(8, "无法备份并重置本地 Web profile。" + (detail.isEmpty ? "" : "\n\n\(detail)"))
    }
    do {
        return try JSONDecoder().decode(ProfileRecoveryResult.self, from: Data(outcome.stdout.utf8))
    } catch {
        throw failure(9, "本地环境恢复工具返回了无效结果。")
    }
}

private struct WebPluginCandidate: Decodable {
    let name: String
    let spec: String
    let signals: [String]
}

private struct WebPluginDiagnosis: Decodable {
    let profileExists: Bool
    let manifestValid: Bool
    let candidates: [WebPluginCandidate]
}

private func diagnoseWebPlugins(resources: HarnessResources, failureText: String) throws -> WebPluginDiagnosis {
    let outcome = try CapturedCommand().run(
        resources: resources,
        arguments: [resources.diagnosisScript.path],
        input: Data(failureText.utf8),
        timeout: 30
    )
    guard outcome.status == 0 else {
        let detail = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw failure(12, "无法分析启动失败原因。" + (detail.isEmpty ? "" : "\n\n\(detail)"))
    }
    do {
        return try JSONDecoder().decode(WebPluginDiagnosis.self, from: Data(outcome.stdout.utf8))
    } catch {
        throw failure(13, "启动诊断工具返回了无效结果。")
    }
}

private func removeWebPlugins(resources: HarnessResources, names: [String]) throws {
    let outcome = try CapturedCommand().run(
        resources: resources,
        arguments: [resources.launcher.path, "plugin", "--profile", "web", "remove"] + names,
        timeout: 300
    )
    guard outcome.status == 0 else {
        let detail = (outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw failure(14, "无法卸载不兼容插件（\(names.joined(separator: "、"))）。" + (detail.isEmpty ? "" : "\n\n\(detail)"))
    }
}

private final class HarnessProcess {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var outputBuffer = Data()
    private var errorTail = Data()
    private var ready = false
    private var stopping = false
    private let maximumErrorBytes = 32 * 1024

    var onReady: ((URL) -> Void)?
    var onExit: ((String, Bool) -> Void)?

    func start(resources: HarnessResources, mode: MarketLaunchMode) throws {
        process.executableURL = resources.node
        process.arguments = mode.arguments(resources: resources)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = resources.environment()
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] in self?.consumeOutput($0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { [weak self] in self?.consumeError($0.availableData) }
        process.terminationHandler = { [weak self] task in self?.processExited(task) }
        try process.run()
    }

    func stop(timeout: TimeInterval = 6) {
        lock.withLock { stopping = true }
        guard process.isRunning else { closePipes(); return }
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        closePipes()
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        var foundURL: URL?
        lock.withLock {
            outputBuffer.append(data)
            while let newline = outputBuffer.firstIndex(of: 0x0a) {
                let lineData = outputBuffer.prefix(upTo: newline)
                outputBuffer.removeSubrange(...newline)
                if !ready, let line = String(data: lineData, encoding: .utf8), let url = readinessURL(from: line) {
                    ready = true
                    foundURL = url
                }
            }
        }
        if let foundURL { DispatchQueue.main.async { self.onReady?(foundURL) } }
    }

    private func consumeError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            errorTail.append(data)
            if errorTail.count > maximumErrorBytes { errorTail.removeFirst(errorTail.count - maximumErrorBytes) }
        }
    }

    private func processExited(_ task: Process) {
        consumeOutput(output.fileHandleForReading.readDataToEndOfFile())
        consumeError(errors.fileHandleForReading.readDataToEndOfFile())
        closePipes()
        let state = lock.withLock { (stopping, ready, String(data: errorTail, encoding: .utf8) ?? "") }
        guard !state.0 else { return }
        let prefix = state.1 ? "Harness 后台进程意外退出" : "Harness 启动失败"
        let detail = state.2.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "\(prefix)（状态码 \(task.terminationStatus)）。" + (detail.isEmpty ? "" : "\n\n\(detail)")
        let wasReady = state.1
        DispatchQueue.main.async { self.onExit?(message, wasReady) }
    }

    private func closePipes() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var harness = HarnessProcess()
    private var resources: HarnessResources?
    private let container = NSView()
    private var webView: WKWebView?
    private var harnessOrigin: String?
    private var lastMarketChoice: MarketLaunchMode?
    private var lastHadLocalMarket: Bool?
    private var pendingUninstall: [WebPluginCandidate]?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 900, height: 620)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = container
        replaceContent(with: statusView(title: "正在启动 DeepSeek Harness…", detail: "首次启动可能需要几秒钟。", spinning: true))
        configureHarness()
    }

    required init?(coder: NSCoder) { nil }

    func start() {
        do {
            let loaded = try HarnessResources.load()
            resources = loaded
            try startHarness(resources: loaded)
        } catch {
            handleStartupFailure(error.localizedDescription)
        }
    }

    func stop() { harness.stop() }

    func showMainWindow() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let delegate = NSApp.delegate as? AppDelegate, !delegate.isQuitting else { return true }
        sender.orderOut(nil)
        return false
    }

    private func configureHarness() {
        harness.onReady = { [weak self] url in self?.open(url) }
        harness.onExit = { [weak self] message, wasReady in
            guard let self else { return }
            if wasReady {
                self.showError(message)
            } else {
                self.handleStartupFailure(message)
            }
        }
    }

    private func startHarness(resources: HarnessResources) throws {
        let hasLocalMarket = try detectsLocalMarket(resources: resources)
        let hadLocalMarket = lastHadLocalMarket ?? false
        let mode: MarketLaunchMode
        if hasLocalMarket {
            if let previous = lastMarketChoice, hadLocalMarket {
                mode = previous
            } else {
                guard let choice = chooseMarketSource() else {
                    NSApp.terminate(nil)
                    return
                }
                lastMarketChoice = choice
                mode = choice
            }
        } else {
            lastMarketChoice = nil
            mode = .bundled
        }
        lastHadLocalMarket = hasLocalMarket
        try harness.start(resources: resources, mode: mode)
    }

    private func chooseMarketSource() -> MarketLaunchMode? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检测到插件市场冲突"
        alert.informativeText = "本地 Web profile 和安装包都包含插件市场，同一时间只能启用一个。请选择本次启动使用的来源。其他本地插件、会话和凭据不会被删除或重置。"
        alert.addButton(withTitle: "使用本地插件市场")
        alert.addButton(withTitle: "使用安装包内置市场")
        alert.addButton(withTitle: "退出")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .local
        case .alertSecondButtonReturn:
            return .bundledReplacingLocal
        default:
            return nil
        }
    }

    private func open(_ url: URL) {
        harnessOrigin = origin(of: url)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsMagnification = true
        webView = view
        replaceContent(with: view)
        view.load(URLRequest(url: url))
    }

    private func handleStartupFailure(_ message: String) {
        var candidates: [WebPluginCandidate] = []
        if let resources {
            do {
                candidates = try diagnoseWebPlugins(resources: resources, failureText: message).candidates
            } catch {
                // 诊断失败只隐藏“卸载并重启”入口，原始启动错误仍完整展示。
            }
        }
        showStartupFailure(message, candidates: candidates)
    }

    private func showStartupFailure(_ message: String, candidates: [WebPluginCandidate]) {
        pendingUninstall = candidates.isEmpty ? nil : candidates
        var actions: [NSView] = []
        let title: String
        let detail: String
        if candidates.isEmpty {
            title = "无法启动应用"
            detail = message
        } else {
            let names = candidates.map(\.name).joined(separator: "、")
            title = "启动时检测到插件不兼容"
            detail = "以下已安装插件与当前 DeepSeek Harness 版本不兼容，导致启动失败：\n\n\(names)\n\n"
                + "可以卸载这些插件后自动重启；会话、设置和凭据不会受影响。\n\n失败详情：\n\(message)"
            let uninstallTitle = candidates.count == 1 ? "卸载「\(candidates[0].name)」并重启" : "卸载不兼容插件并重启"
            actions.append(actionButton(title: uninstallTitle, action: #selector(uninstallIncompatiblePlugins)))
        }
        actions.append(actionButton(title: "备份并重置 Web profile，然后重新打开", action: #selector(recoverWebProfile)))
        replaceContent(with: statusView(title: title, detail: detail, spinning: false, actions: actions))
    }

    private func showError(_ message: String) {
        pendingUninstall = nil
        let button = actionButton(title: "备份并重置 Web profile，然后重新打开", action: #selector(recoverWebProfile))
        replaceContent(with: statusView(title: "无法启动应用", detail: message, spinning: false, actions: [button]))
    }

    @objc private func uninstallIncompatiblePlugins() {
        guard let resources, let names = pendingUninstall?.map(\.name), !names.isEmpty else { return }
        replaceContent(with: statusView(
            title: "正在卸载不兼容插件…",
            detail: "将卸载：\n\(names.joined(separator: "、"))\n\n卸载完成后会自动重启应用。",
            spinning: true
        ))
        harness.stop()
        do {
            try removeWebPlugins(resources: resources, names: names)
            pendingUninstall = nil
            harnessOrigin = nil
            webView = nil
            harness = HarnessProcess()
            configureHarness()
            replaceContent(with: statusView(title: "正在重新启动 DeepSeek Harness…", detail: "不兼容插件已卸载，正在重新启动。", spinning: true))
            try startHarness(resources: resources)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func recoverWebProfile() {
        guard let resources else { return }
        replaceContent(with: statusView(title: "正在恢复本地环境…", detail: "系统会先备份 Web profile；会话、设置、凭据和个人 preset 不受影响。", spinning: true))
        harness.stop()
        do {
            let result = try resetWebProfile(resources: resources)
            pendingUninstall = nil
            lastMarketChoice = nil
            lastHadLocalMarket = nil
            harnessOrigin = nil
            webView = nil
            harness = HarnessProcess()
            configureHarness()
            let detail = result.backup.map { "旧 Web profile 已备份到：\n\($0)" } ?? "未发现需要备份的 Web profile，正在重新启动。"
            replaceContent(with: statusView(title: "正在重新启动 DeepSeek Harness…", detail: detail, spinning: true))
            try startHarness(resources: resources)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func actionButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func statusView(title: String, detail: String, spinning: Bool, actions: [NSView] = []) -> NSView {
        let wrapper = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 12
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        for action in actions {
            stack.addArrangedSubview(action)
        }
        if spinning {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .large
            indicator.startAnimation(nil)
            stack.insertArrangedSubview(indicator, at: 0)
        }
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor, constant: 60),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -60),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
        ])
        return wrapper
    }

    private func replaceContent(with view: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host, let port = url.port else { return nil }
        return "\(scheme)://\(host):\(port)"
    }

    private func isHarnessURL(_ url: URL) -> Bool { origin(of: url) == harnessOrigin }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if isHarnessURL(url) || url.scheme == "about" || url.scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?
    private var statusItem: NSStatusItem?
    var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        installStatusItem()
        let controller = MainWindowController()
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isQuitting = true
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        statusItem = nil
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let button = item.button
        button?.image = Self.statusImage()
        button?.imagePosition = .imageOnly
        button?.toolTip = appName
        button?.target = self
        button?.action = #selector(statusItemClicked(_:))
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private static func statusImage() -> NSImage {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            icon.size = NSSize(width: 18, height: 18)
            return icon
        }
        return NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.labelColor.setFill()
            rect.fill()
            return true
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, event.type == .rightMouseUp else {
            showMainWindow()
            return
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "显示 DeepSeek Harness", action: #selector(showMainWindowFromMenu(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 DeepSeek Harness", action: #selector(quitFromStatusItem(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func showMainWindowFromMenu(_ sender: Any?) { showMainWindow() }

    @objc private func quitFromStatusItem(_ sender: Any?) { NSApp.terminate(nil) }

    func showMainWindow() {
        controller?.showMainWindow()
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = menu
    }
}

@main
private enum DeepSeekHarnessApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
