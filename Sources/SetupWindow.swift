// Set up Strata, for a Mac without it: check whether this Mac can run Strata, then install Strata's latest release
// and let Strata's own setup pick the model by this Mac's memory (./setup.sh --yes --no-start).
//
// The install runs as a launchd job, so closing the window or quitting StrataBar does not stop a download. Strata's
// setup is resumable: Retry runs the same command again and it continues where it stopped.

import AppKit
import SwiftUI

struct Check: Identifiable {
    enum Level { case ok, warn, fail }
    let id = UUID()
    let level: Level
    let text: String

    var symbol: String {
        switch level {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch level {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        }
    }
}

/// What this Mac has, and what Strata's setup is expected to do with it. The pack is an estimate from Strata's
/// docs/MAC.md; setup makes the choice itself.
struct Preflight {
    var checks: [Check] = []
    var pack = ""
    var needGB = 0.0
    var commandLineTools = true
    var resuming = false                    // the folder holds Strata already: an install that did not finish

    var canInstall: Bool { !checks.isEmpty && !checks.contains { $0.level == .fail } }

    static let minMemoryGB = 32.0           // the smallest Mac Strata was measured on (an M4 with 32 GB, streaming)
    static let residentFromGB = 64.0        // below this the engine reads part of the model from the SSD
    // the pack setup recommends from this much memory (docs/MAC.md), and its download (setup.py's MODELS)
    static let packs: [(name: String, fromGB: Double, downloadGB: Double)] = [
        ("IQ3_S", 96, 83.6), ("IQ3_XXS", 74, 75.8), ("Q2_0", 0, 66.4),
    ]

    static func run(dir: String) -> Preflight {
        var p = Preflight()
        let chip = sysctlString("machdep.cpu.brand_string") ?? "This Mac"
        p.checks.append(sysctlInt("hw.optional.arm64") == 1
            ? Check(level: .ok, text: "\(chip) (Apple Silicon)")
            : Check(level: .fail, text: "\(chip): Strata needs Apple Silicon (M1 or newer)"))

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "macOS \(os.majorVersion).\(os.minorVersion)"
        p.checks.append(os.majorVersion >= 15
            ? Check(level: .ok, text: version)
            : Check(level: .fail, text: "\(version): Strata needs macOS 15 or newer"))

        p.commandLineTools = run("/usr/bin/xcode-select", ["-p"]) == 0              // as Strata's setup checks
        p.checks.append(p.commandLineTools
            ? Check(level: .ok, text: "Command Line Tools")
            : Check(level: .fail, text: "Command Line Tools missing: Strata's engine is built with them"))

        let memory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824   // GB as Apple sells them
        let pack = packs.first { memory >= $0.fromGB } ?? packs[packs.count - 1]
        if memory < minMemoryGB {
            p.checks.append(Check(level: .fail, text: String(format: "%.0f GB memory: not enough to run Strata "
                + "(it needs %.0f GB or more)", memory, minMemoryGB)))
        } else {
            p.pack = pack.name
            p.checks.append(memory < residentFromGB
                ? Check(level: .warn, text: String(format: "%.0f GB memory: %@, with part of the model read from the "
                    + "SSD while it runs (slower)", memory, pack.name))
                : Check(level: .ok, text: String(format: "%.0f GB memory: %@ (Strata's setup confirms the choice)",
                                                 memory, pack.name)))
        }

        // the model files go to Strata-data next to the Strata folder: setup's own margin is 6 GB, and the Strata
        // folder (the engine build, Python) takes about 5 GB
        // (a resumed install has part of that on the disk already, so there a shortfall is only a warning)
        p.needGB = pack.downloadGB + 6 + 5
        p.resuming = FileManager.default.fileExists(atPath: dir + "/setup.sh")
        let parent = URL(fileURLWithPath: (dir as NSString).deletingLastPathComponent)
        let free = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { Double($0) / 1e9 } ?? 0
        p.checks.append(free >= p.needGB
            ? Check(level: .ok, text: String(format: "%.0f GB free on the disk (about %.0f GB needed)", free, p.needGB))
            : Check(level: p.resuming ? .warn : .fail, text: String(format: "%.0f GB free on the disk: Strata needs "
                + "about %.0f GB%@", free, p.needGB, p.resuming ? " in all (part of it is downloaded)" : "")))
        return p
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : 0
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Where a running or finished install stands, read from its launchd job and its log
struct SetupStatus {
    var loaded = false
    var running = false
    var exitCode: Int?
    var step = ""                   // setup's last "Step N: ..."
    var progress: Double?           // the running download's fraction
    var detail = ""                 // the running download's line
    var error = ""                  // setup's last "[X]" line
}

@MainActor
final class SetupController: ObservableObject {
    enum Phase: Equatable { case idle, running, failed(String), done }

    nonisolated static let upstream = "Niko1221/Strata"

    @Published private(set) var preflight = Preflight()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = SetupStatus()
    @Published private(set) var release = ""                // the Strata release to install, e.g. v0.1.44.1
    @Published private(set) var releaseError = ""
    var onDone: (() -> Void)?
    private var timer: Timer?

    var isRunning: Bool { phase == .running }

    init() {
        Task {
            // an install started before StrataBar was quit: show it, or how it ended
            if await Self.jobStatus().loaded { phase = .running; watch() }
        }
    }

    func check() {
        preflight = Preflight.run(dir: Paths.strataDir)
        guard release.isEmpty else { return }
        Task {
            do { release = try await Self.latestRelease(); releaseError = "" }
            catch { releaseError = "Cannot reach GitHub for Strata's latest release: \(error.localizedDescription)" }
        }
    }

    func installCommandLineTools() {
        Preflight.run("/usr/bin/xcode-select", ["--install"])             // Apple's own installer dialog
    }

    /// a resumed install needs no release: the folder has Strata, and the job goes on with its setup
    var canInstall: Bool { preflight.canInstall && (preflight.resuming || !release.isEmpty) }

    func install() {
        guard canInstall else { return }
        phase = .running
        status = SetupStatus(loaded: true, running: true)
        let dir = Paths.strataDir, tag = release
        Task {
            do { try await Self.startJob(dir: dir, repo: "https://github.com/\(Self.upstream).git", tag: tag) }
            catch { phase = .failed(error.localizedDescription); return }
            watch()
        }
    }

    func showLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: Paths.setupLog)], withApplicationAt: console,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await poll() }
    }

    private func poll() async {
        let s = await Self.jobStatus()
        status = s
        guard !s.running else { return }
        timer?.invalidate()
        _ = await StrataController.launchctl(["bootout", "\(Paths.domain)/\(Paths.setupLabel)"])
        if s.exitCode == 0 {
            phase = .done
            onDone?()
        } else {
            phase = .failed(s.error.isEmpty ? "Setup stopped (exit code \(s.exitCode.map(String.init) ?? "?"))"
                                            : s.error)
        }
    }

    // MARK: the job

    nonisolated static func latestRelease() async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(upstream)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("StrataBar", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { throw ControlError("no release found") }
        return tag
    }

    /// Writes the install script and its launchd job, and starts it: a clone of `repo` at `tag` into `dir` unless
    /// `dir` holds Strata already (a Retry), then Strata's setup with the recommended answers
    nonisolated static func startJob(dir: String, repo: String, tag: String) async throws {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
            #!/bin/bash
            # written by StrataBar: Strata \(tag) into \(dir), then Strata's setup (run again, it continues)
            set -eu
            DIR=\(q(dir))
            if [ ! -e "$DIR/setup.sh" ]; then
              echo "=== Step 0: downloading Strata \(tag) ==="
              git clone \(q(repo)) "$DIR"
              git -C "$DIR" checkout -q -B main \(q(tag))   # main at the release: Strata's update.sh pulls from there
            fi
            cd "$DIR"
            exec ./setup.sh --yes --no-start
            """
        let job: [String: Any] = [
            "Label": Paths.setupLabel,
            "ProgramArguments": ["/bin/bash", Paths.setupScript],
            "WorkingDirectory": Paths.home,
            "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                     "PYTHONUNBUFFERED": "1"],
            "RunAtLoad": true,                          // once: no KeepAlive, a failure waits for Retry
            "ProcessType": "Interactive",
            "StandardOutPath": Paths.setupLog,
            "StandardErrorPath": Paths.setupLog,
        ]
        let fm = FileManager.default
        for path in [Paths.setupScript, Paths.setupLog] {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        try script.write(toFile: Paths.setupScript, atomically: true, encoding: .utf8)
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: Paths.setupPlist))
        if fm.fileExists(atPath: Paths.setupLog) {                // the last attempt's log, for comparison
            try? fm.removeItem(atPath: Paths.setupLog + ".1")
            try? fm.moveItem(atPath: Paths.setupLog, toPath: Paths.setupLog + ".1")
        }
        _ = await StrataController.launchctl(["bootout", "\(Paths.domain)/\(Paths.setupLabel)"])   // an old run
        let (status, out) = await StrataController.launchctl(["bootstrap", Paths.domain, Paths.setupPlist])
        if status != 0 { throw ControlError("Setup could not start: \(out.isEmpty ? "launchctl \(status)" : out)") }
    }

    nonisolated static func jobStatus() async -> SetupStatus {
        var s = SetupStatus()
        let (code, out) = await StrataController.launchctl(["print", "\(Paths.domain)/\(Paths.setupLabel)"])
        s.loaded = code == 0
        if s.loaded {
            s.running = out.contains("state = running")
            if let r = out.range(of: #"last exit code = (-?\d+)"#, options: .regularExpression) {
                s.exitCode = Int(out[r].split(separator: " ").last ?? "")
            }
        }
        readLog(into: &s)
        return s
    }

    /// The step, the download and the error from the end of setup's log (its download lines end in \r)
    nonisolated static func readLog(into s: inout SetupStatus) {
        guard let handle = FileHandle(forReadingAtPath: Paths.setupLog) else { return }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let lines = text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let step = lines.last(where: { $0.hasPrefix("=== Step ") }) {
            s.step = step.replacingOccurrences(of: "=== ", with: "").replacingOccurrences(of: " ===", with: "")
        }
        if let last = lines.last, let r = last.range(of: #"\(\d+%\)"#, options: .regularExpression) {
            s.detail = last                         // "<file>: 12.34 / 83.60 GB (15%)"
            s.progress = Double(last[r].dropFirst().dropLast(2)).map { $0 / 100 }
        }
        if let error = lines.last(where: { $0.hasPrefix("[X]") }) {
            s.error = error.dropFirst(3).trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: the window

struct SetupWindow: View {
    @ObservedObject var setup: SetupController
    @ObservedObject var strata: StrataController
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Strata").font(.title2.bold())
            switch setup.phase {
            case .idle: checks
            case .running: running
            case .failed(let message): failed(message)
            case .done: done
            }
        }
        .padding(24)
        .frame(width: 560, alignment: .leading)
        .onAppear { if setup.phase == .idle { setup.check() } }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(setup.preflight.resuming
                 ? "The Strata setup in \(tilde(Paths.strataDir)) did not finish. It continues where it stopped."
                 : "Strata is not installed in \(tilde(Paths.strataDir)). StrataBar can check this Mac and set it up.")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(setup.preflight.checks) { c in
                    Label { Text(c.text) } icon: { Image(systemName: c.symbol).foregroundStyle(c.color) }
                }
            }
            if setup.preflight.canInstall && !setup.preflight.resuming {
                Text("This downloads Strata \(setup.release.isEmpty ? "(latest release)" : setup.release) from "
                     + "github.com/\(SetupController.upstream) into \(tilde(Paths.strataDir)), and about "
                     + "\(Int(setup.preflight.needGB - 11)) GB of model files into \(tilde(Paths.strataDir))-data. "
                     + "It takes an hour or more on a slow connection; it can be stopped and resumed.")
                    .foregroundStyle(.secondary)
            } else if !setup.preflight.checks.isEmpty {
                Text("This Mac cannot run Strata: see the items marked in red.").foregroundStyle(.red)
            }
            if !setup.releaseError.isEmpty {
                Text(setup.releaseError).foregroundStyle(.red)
            }
            HStack {
                Button("Choose Existing Folder…") { strata.chooseFolder() }
                Spacer()
                if !setup.preflight.commandLineTools {
                    Button("Install Command Line Tools…") { setup.installCommandLineTools() }
                }
                Button("Check Again") { setup.check() }
                Button(setup.preflight.resuming ? "Continue Setup" : "Install Strata") { setup.install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!setup.canInstall)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(setup.status.step.isEmpty ? "Starting…" : setup.status.step).font(.headline)
            if let p = setup.status.progress {
                ProgressView(value: p) { Text(setup.status.detail).font(.callout.monospacedDigit()) }
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text("You can close this window: the setup keeps running, and the menu shows it.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Show Log") { setup.showLog() }
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(message) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
            Text("Retry continues where the setup stopped.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Show Log") { setup.showLog() }
                Button("Retry") { setup.check(); setup.install() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text("Strata is installed\(strata.configs.isEmpty ? "" : ": " + strata.configs.joined(separator: ", ")).") }
                icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            HStack {
                Spacer()
                Button("Start Service") {
                    strata.start()
                    dismissWindow(id: "setup")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(strata.configs.isEmpty)
            }
        }
    }

    private func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
