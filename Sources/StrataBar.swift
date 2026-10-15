// StrataBar: a macOS menu bar app for the Strata server (https://github.com/Niko1221/Strata), in the style of
// Ollama's.
//
// The server runs as a launchd job, not as a child of this app: quitting the app or closing a terminal leaves the
// model as it is. Start/Stop load and unload that job (launchctl bootstrap/bootout); Pause/Resume use the server's
// own POST /unload and /load, so the HTTP server stays up while the model is unloaded.
// Note: while paused, any API request loads the model again (the server does that by itself) - Stop is the hard off.

import AppKit
import SwiftUI
import WebKit

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let jobLabel = "io.github.fengzhyuan.StrataBar.server"
    // written on every Start, so it always matches the chosen run config; deliberately not in ~/Library/LaunchAgents:
    // KeepAlive implies RunAtLoad, so launchd would start the model at every login
    static let jobPlist = home + "/Library/Application Support/StrataBar/server.plist"
    static let log = home + "/Library/Logs/StrataBar/server.log"
    static let setupLabel = "io.github.fengzhyuan.StrataBar.setup"         // Set up Strata (SetupWindow.swift)
    static let setupPlist = home + "/Library/Application Support/StrataBar/setup.plist"
    static let setupScript = home + "/Library/Application Support/StrataBar/setup-strata.sh"
    static let setupLog = home + "/Library/Logs/StrataBar/setup.log"
    static var domain: String { "gui/\(getuid())" }

    /// Strata's folder (where its setup.sh ran): ~/Strata unless chosen in the menu
    static var strataDir: String {
        get { UserDefaults.standard.string(forKey: "strataDir") ?? home + "/Strata" }
        set { UserDefaults.standard.set(newValue, forKey: "strataDir") }
    }
}

/// One of the run configs setup writes, strata-<model>.json in Strata's folder. Read on every use: a key or port
/// changed in the config applies without restarting this app.
struct RunConfig {
    var path: String
    var name: String                                    // <model>
    var port = 8080                                     // setup's default when the config has none
    var host = "127.0.0.1"
    var apiKey = ""
    var apiMonitor = false                              // "api_monitor": the server serves /api-monitor

    /// the strata-*.json files that name an engine ("exe"), by name
    static func all() -> [RunConfig] {
        let dir = Paths.strataDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasPrefix("strata-") && $0.hasSuffix(".json") }.sorted()
            .compactMap { load(dir + "/" + $0) }
    }

    /// the config chosen in the menu, else the first one
    static func current() -> RunConfig? {
        let configs = all()
        let chosen = UserDefaults.standard.string(forKey: "config")
        return configs.first { $0.name == chosen } ?? configs.first
    }

    static func load(_ path: String) -> RunConfig? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["exe"] is String
        else { return nil }
        let file = (path as NSString).lastPathComponent
        var c = RunConfig(path: path, name: String(file.dropFirst("strata-".count).dropLast(".json".count)))
        if let p = obj["port"] as? Int { c.port = p }
        if let h = obj["host"] as? String, !["", "0.0.0.0", "::"].contains(h) { c.host = h }   // all interfaces
        if let k = obj["api_key"] as? String { c.apiKey = k }
        c.apiMonitor = obj["api_monitor"] as? Bool ?? false
        return c
    }

    var baseURL: URL { URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)/")! }
}

enum ServiceState {
    case stopped, starting, loaded, paused, loading, pausing, stopping, installing

    var title: String {
        switch self {
        case .installing: "Setting up Strata…"
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .loaded: "Running"
        case .paused: "Paused (model unloaded)"
        case .loading: "Loading model…"
        case .pausing: "Pausing…"
        case .stopping: "Stopping…"
        }
    }

    var isBusy: Bool {
        switch self {
        case .stopped, .loaded, .paused: false
        default: true
        }
    }
}

struct ControlError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class StrataController: ObservableObject {
    @Published private(set) var observed: ServiceState = .stopped
    @Published private(set) var action: ServiceState?       // a change this app started, shown until it ends
    @Published private(set) var model = ""
    @Published private(set) var managed = false             // the launchd job is loaded: Stop Service applies
    @Published private(set) var lastError: String?
    @Published private(set) var frame = 0                   // the menu bar glyph's animation while busy
    @Published private(set) var configs: [String] = []      // the run configs' model names
    @Published private(set) var selectedConfig = ""
    @Published private(set) var apiMonitor = false          // the chosen config turns the API monitor on
    let setup = SetupController()                           // Set up Strata, when there is none
    private var timer: Timer?
    private var animator: Timer?

    var state: ServiceState { action ?? observed }

    var glyph: StrataIcon.Glyph {
        switch state {
        case .loaded: .loaded
        case .paused: .paused
        case .stopped: .stopped
        default: .busy(frame)
        }
    }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        animator = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let self, self.state.isBusy { self.frame += 1 }
            }
        }
        setup.onDone = { [weak self] in Task { await self?.refresh() } }
        Task { await refresh() }
    }

    func refresh() async {
        configs = RunConfig.all().map(\.name)
        let cfg = RunConfig.current()
        selectedConfig = cfg?.name ?? ""
        apiMonitor = cfg?.apiMonitor ?? false
        async let job = Self.jobLoaded()
        let h: Health? = if let cfg { await Self.health(cfg) } else { nil }
        let j = await job
        managed = j
        if let h { model = h.model }
        // the HTTP server only answers once the model is loaded, so "job loaded, no answer" is a start in progress
        observed = h.map { $0.loaded ? .loaded : .paused } ?? (j ? .starting : setup.isRunning ? .installing : .stopped)
        if action == .starting && observed != .starting { action = nil }
    }

    func start() {
        perform(.starting, clearWhenDone: false) {
            guard let cfg = RunConfig.current() else {
                throw ControlError("No run config (strata-<model>.json) in \(Paths.strataDir)")
            }
            try Self.writeJob(cfg)
            let (status, out) = await Self.launchctl(["bootstrap", Paths.domain, Paths.jobPlist])
            if status != 0 { throw ControlError("Start failed: \(out.isEmpty ? "launchctl \(status)" : out)") }
        }
    }

    func stop() {
        perform(.stopping) {
            let (status, out) = await Self.launchctl(["bootout", "\(Paths.domain)/\(Paths.jobLabel)"])
            if status != 0 { throw ControlError("Stop failed: \(out.isEmpty ? "launchctl \(status)" : out)") }
        }
    }

    func pause() {
        perform(.pausing) {
            // wait=1: the server waits (up to 300 s) for a running answer instead of refusing at once
            let (code, message) = try await Self.post("/unload?wait=1", timeout: 330)
            if code == 409 { throw ControlError("The model is answering; try pausing again shortly") }
            if code != 200 { throw ControlError("Pause failed: \(message)") }
        }
    }

    func resume() {
        perform(.loading) {
            let (code, message) = try await Self.post("/load", timeout: 900)   // answers once the model is loaded
            if code != 200 { throw ControlError("Load failed: \(message)") }
        }
    }

    func choose(_ name: String) {
        UserDefaults.standard.set(name, forKey: "config")
        Task { await refresh() }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Strata folder (where setup.sh wrote strata-<model>.json)"
        panel.directoryURL = URL(fileURLWithPath: Paths.strataDir)
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            Paths.strataDir = url.path
            Task { await refresh() }
        }
    }

    func copyAPIAddress() {
        guard let cfg = RunConfig.current() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cfg.baseURL.absoluteString + "v1", forType: .string)
    }

    func showLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: Paths.log)], withApplicationAt: console,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func perform(_ transition: ServiceState, clearWhenDone: Bool = true,
                         _ work: @escaping () async throws -> Void) {
        guard action == nil else { return }
        action = transition
        lastError = nil
        Task {
            do {
                try await work()
                if clearWhenDone { action = nil }
            } catch {
                lastError = error.localizedDescription
                action = nil
            }
            await refresh()
        }
    }

    // MARK: server and launchd access

    struct Health { let loaded: Bool; let model: String }

    nonisolated static func health(_ cfg: RunConfig) async -> Health? {
        var req = URLRequest(url: cfg.baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Health(loaded: obj["loaded"] as? Bool ?? false, model: obj["model"] as? String ?? "")
    }

    // POST /unload and /load accept only JSON without a foreign Origin, and the API key when the config has one
    nonisolated static func post(_ path: String, timeout: TimeInterval) async throws -> (Int, String) {
        guard let cfg = RunConfig.current() else { throw ControlError("No run config") }
        var req = URLRequest(url: URL(string: path, relativeTo: cfg.baseURL)!.absoluteURL)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout                   // /load sends nothing until the model is loaded
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty { req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (obj?["error"] as? [String: Any])?["message"] as? String
            ?? obj?["status"] as? String ?? "HTTP \(code)"
        return (code, message)
    }

    /// The launchd job: the command setup writes into run-<model>.sh, without --open (no browser tab per start).
    /// The port is passed as there, from the config, so the server and this app agree on it.
    nonisolated static func writeJob(_ cfg: RunConfig) throws {
        let dir = Paths.strataDir
        let python = dir + "/.venv/bin/python", server = dir + "/serve/server.py"
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: python), fm.fileExists(atPath: server) else {
            throw ControlError("Strata is not set up in \(dir): run its ./setup.sh first")
        }
        let job: [String: Any] = [
            "Label": Paths.jobLabel,
            "ProgramArguments": [python, server, "--engine", "strata", "--config", cfg.path, "--port", "\(cfg.port)"],
            "WorkingDirectory": dir,
            "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                     "PYTHONUNBUFFERED": "1"],
            "KeepAlive": ["SuccessfulExit": false],     // restart after a crash; a clean exit (bootout) stays stopped
            "ThrottleInterval": 30,
            "ExitTimeOut": 60,                          // the engine needs a while to free its memory (default 20 s)
            "ProcessType": "Interactive",               // unspecified means CPU and I/O throttling
            "StandardOutPath": Paths.log,
            "StandardErrorPath": Paths.log,
        ]
        for path in [Paths.jobPlist, Paths.log] {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: Paths.jobPlist))
    }

    nonisolated static func jobLoaded() async -> Bool {
        await launchctl(["print", "\(Paths.domain)/\(Paths.jobLabel)"]).0 == 0
    }

    nonisolated static func launchctl(_ args: [String]) async -> (Int32, String) {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { done.resume(returning: (-1, "\(error)")); return }
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                done.resume(returning: (p.terminationStatus, text))
            }
        }
    }
}

// MARK: menu

struct MenuContent: View {
    @ObservedObject var strata: StrataController
    @ObservedObject var setup: SetupController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = strata.state
        Text("Strata · \(s.title)")
        if s == .installing && !setup.status.step.isEmpty {
            Text(setup.status.step + (setup.status.progress.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
        }
        if !strata.model.isEmpty && s != .stopped {
            Text(strata.model)
        }
        if strata.configs.isEmpty {
            Text("No run config (strata-<model>.json) in \((Paths.strataDir as NSString).abbreviatingWithTildeInPath)")
        }
        if s != .stopped && s != .stopping && !strata.managed {
            Text("Started outside StrataBar: stop it from its terminal")
        }
        if let e = strata.lastError {
            Text("⚠️ \(e)")
        }
        Divider()
        Button("Open Chat Window") { open("chat") }
        Button("Open API Monitor") { open("monitor") }
            .disabled(!strata.apiMonitor)               // the server has no /api-monitor without "api_monitor"
        switch s {
        case .loaded: Button("Pause") { strata.pause() }
        case .paused: Button("Resume") { strata.resume() }
        default: Button("Pause") {}.disabled(true)
        }
        if s == .stopped {
            Button("Start Service") { strata.start() }.disabled(strata.configs.isEmpty)
        } else {
            Button("Stop Service") { strata.stop() }.disabled(!strata.managed || s == .stopping)
        }
        Divider()
        if strata.configs.isEmpty {
            Button("Set Up Strata…") { open("setup") }
            Button("Choose Strata Folder…") { strata.chooseFolder() }
        } else if strata.configs.count > 1 {
            Menu("Model") {
                Picker("Model", selection: Binding(get: { strata.selectedConfig }, set: { strata.choose($0) })) {
                    ForEach(strata.configs, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(s != .stopped)                // a model change takes a stop first
                Divider()
                Button("Choose Strata Folder…") { strata.chooseFolder() }
            }
        }
        Button("Copy API URL") { strata.copyAPIAddress() }
        Button("Show Log") { strata.showLog() }
        Divider()
        Button("Quit StrataBar") { NSApp.terminate(nil) }
    }

    // the Dock icon first, so the window opens in front with the app's menu bar (AppDelegate takes it away again)
    private func open(_ id: String) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate()
    }
}

// MARK: windows: Strata's own web pages

enum StrataPage {
    case chat       // the web app, /
    case monitor    // the API request monitor, /api-monitor

    func url(_ cfg: RunConfig) -> URL {
        self == .chat ? cfg.baseURL : cfg.baseURL.appendingPathComponent("api-monitor")
    }

    // each page keeps the API key where it reads it before its first request: set it there from the run config,
    // so the window needs no typing and a key changed in the config applies on the next open
    func keyScript(_ cfg: RunConfig) -> String {
        guard !cfg.apiKey.isEmpty, let json = try? JSONSerialization.data(withJSONObject: [cfg.apiKey]) else { return "" }
        let key = String(decoding: json, as: UTF8.self) + "[0]"            // a safely quoted JavaScript string
        return switch self {
        case .chat: "try { localStorage.setItem('strata.apikey', JSON.stringify(\(key))) } catch (e) {}"
        case .monitor: "try { sessionStorage.setItem('strata.monitor.key', \(key)) } catch (e) {}"
        }
    }
}

struct PageWindow: View {
    @ObservedObject var strata: StrataController
    let page: StrataPage

    var body: some View {
        switch strata.state {
        case .stopped:
            VStack(spacing: 12) {
                Text("The Strata service is not running").font(.title2)
                Button("Start Service") { strata.start() }.disabled(strata.configs.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .starting:
            ProgressView("Starting: loading the model takes 1–3 minutes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if let cfg = RunConfig.current() {
                if page == .monitor && !cfg.apiMonitor {
                    Text("The API monitor is off. Add \"api_monitor\": true to \((cfg.path as NSString).lastPathComponent) and restart the service.")
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    StrataWebView(url: page.url(cfg), setup: page.keyScript(cfg))
                }
            }
        }
    }
}

struct StrataWebView: NSViewRepresentable {
    let url: URL
    let setup: String                                   // JavaScript run before the page's own scripts

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if !setup.isEmpty {
            config.userContentController.addUserScript(
                WKUserScript(source: setup, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
        // <input type="file"> (images for the vision model)
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }

        // target="_blank" links: the default browser
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
            } else if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
                      url.host != webView.url?.host {
                NSWorkspace.shared.open(url)            // a link off the Strata page
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        // <a download> (e.g. a saved image or conversation): into ~/Downloads
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                      completionHandler: @escaping (URL?) -> Void) {
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let name = suggestedFilename as NSString
            var dest = dir.appendingPathComponent(suggestedFilename)
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                let ext = name.pathExtension.isEmpty ? "" : "." + name.pathExtension
                dest = dir.appendingPathComponent("\(name.deletingPathExtension) (\(n))\(ext)")
                n += 1
            }
            completionHandler(dest)
        }
    }
}

// MARK: app

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // as Ollama: a Dock icon (and ⌘Tab) while one of StrataBar's windows is open, else only the menu bar icon.
        // A window shown without the menu (the first start's Set up Strata) brings the icon too.
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            if let w = note.object as? NSWindow, Self.isAppWindow(w), NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, Self.isAppWindow(closing) else { return }
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { $0 !== closing && Self.isAppWindow($0) && $0.isVisible }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        // a menu bar app has no visible main menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z/⌘W are sent to the text field or window directly
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command || mods == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased()
            else { return event }
            if key == "w" && mods == .command {
                NSApp.keyWindow?.performClose(nil)
                return nil
            }
            let selector: Selector? = switch (key, mods == .shift.union(.command)) {
            case ("c", false): #selector(NSText.copy(_:))
            case ("v", false): #selector(NSText.paste(_:))
            case ("x", false): #selector(NSText.cut(_:))
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            default: nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: nil) { return nil }
            return event
        }
    }

    /// the chat, API monitor and setup windows; not the menu bar item, its menu or a panel (an open dialog, an alert)
    static func isAppWindow(_ w: NSWindow) -> Bool { w.styleMask.contains(.titled) && !(w is NSPanel) }
}

@main
struct StrataBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var strata = StrataController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(strata: strata, setup: strata.setup)
        } label: {
            Image(nsImage: StrataIcon.menuBarImage(strata.glyph))
        }
        .menuBarExtraStyle(.menu)

        Window("Strata", id: "chat") {
            PageWindow(strata: strata, page: .chat)
        }
        .defaultSize(width: 1000, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("API Monitor", id: "monitor") {
            PageWindow(strata: strata, page: .monitor)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Set up Strata", id: "setup") {
            SetupWindow(setup: strata.setup, strata: strata)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(RunConfig.all().isEmpty ? .presented : .suppressed)   // the first start without Strata
        .restorationBehavior(.disabled)
    }
}
