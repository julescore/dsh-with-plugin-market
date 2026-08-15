import Cocoa
import Darwin
import WebKit

private let appName = "DSH with Plugin Market"
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

    static func load() throws -> HarnessResources {
        guard let root = Bundle.main.resourceURL else { throw failure(1, "应用资源目录不可用。") }
        let resources = HarnessResources(
            root: root,
            node: root.appendingPathComponent("node/bin/node"),
            launcher: root.appendingPathComponent("runtime/lib/bin.js"),
            marketPatch: root.appendingPathComponent("macos/market.patch.yml"),
            marketConflictPatch: root.appendingPathComponent("macos/market-conflict.patch.yml")
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

private func detectsLocalMarket(resources: HarnessResources) throws -> Bool {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = resources.node
    process.arguments = [resources.launcher.path, "web", "--dump-config"]
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    process.environment = resources.environment()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = "无法检查本地插件配置（状态码 \(process.terminationStatus)）。" + (detail.isEmpty ? "" : "\n\n\(detail)")
        throw failure(5, message)
    }
    guard let config = String(data: outputData, encoding: .utf8) else {
        throw failure(6, "本地插件配置不是有效的 UTF-8 文本。")
    }
    return containsMarketEntry(config)
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
    var onExit: ((String) -> Void)?

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
        DispatchQueue.main.async { self.onExit?(message) }
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

private final class MainWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    private let harness = HarnessProcess()
    private let container = NSView()
    private var webView: WKWebView?
    private var harnessOrigin: String?

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
        window.contentView = container
        replaceContent(with: statusView(title: "正在启动 DSH with Plugin Market…", detail: "首次启动可能需要几秒钟。", spinning: true))
        harness.onReady = { [weak self] url in self?.open(url) }
        harness.onExit = { [weak self] message in self?.showError(message) }
    }

    required init?(coder: NSCoder) { nil }

    func start() {
        do {
            let resources = try HarnessResources.load()
            let hasLocalMarket = try detectsLocalMarket(resources: resources)
            let mode: MarketLaunchMode
            if hasLocalMarket {
                guard let choice = chooseMarketSource() else {
                    NSApp.terminate(nil)
                    return
                }
                mode = choice
            } else {
                mode = .bundled
            }
            try harness.start(resources: resources, mode: mode)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func stop() { harness.stop() }

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

    private func showError(_ message: String) {
        replaceContent(with: statusView(title: "无法启动应用", detail: message, spinning: false))
    }

    private func statusView(title: String, detail: String, spinning: Bool) -> NSView {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        let controller = MainWindowController()
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }

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
