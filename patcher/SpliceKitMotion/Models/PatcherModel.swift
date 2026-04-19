// PatcherModel.swift -- Core model for the SpliceKit Motion GUI patcher.
// Drives the wizard-style UI: welcome -> patching -> complete.
// Handles Motion detection, patch orchestration, and launch.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Types

enum InstallState: Equatable {
    case notInstalled       // No modded Motion found
    case current            // Installed, framework version matches patcher's build
    case updateAvailable    // MotionKit framework version differs from patcher's build
    case motionUpdateAvailable // Stock Motion version changed since modded copy was made
    case unknown
}

enum PatchStep: String, CaseIterable {
    case checkPrereqs = "Checking prerequisites"
    case copyApp = "Copying Motion"
    case buildDylib = "Staging MotionKit dylib"
    case installFramework = "Installing framework"
    case injectDylib = "Injecting into binary"
    case signApp = "Re-signing application"
    case setupMCP = "Setting up MCP server"
    case done = "Done"
}

/// The three panels of the wizard-style patcher UI.
enum WizardPanel: Int {
    case welcome
    case patching
    case complete
}

enum PatchError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self { case .msg(let s): return s }
    }
}

// MARK: - Patcher Log File
//
// Writes to ~/Library/Logs/MotionKit/patcher.log so we have a persistent record
// of every patch attempt — even if Motion crashes on launch and the dylib never loads.

private let patcherLogURL: URL = {
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MotionKit")
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let logFile = logDir.appendingPathComponent("patcher.log")
    let prev = logDir.appendingPathComponent("patcher.previous.log")
    try? FileManager.default.removeItem(at: prev)
    try? FileManager.default.moveItem(at: logFile, to: prev)
    FileManager.default.createFile(atPath: logFile.path, contents: nil)
    return logFile
}()

private func patcherLogWrite(_ text: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(text)\n"
    if let handle = try? FileHandle(forWritingTo: patcherLogURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        handle.closeFile()
    }
}

// MARK: - Model

@MainActor
class PatcherModel: ObservableObject {
    @Published var status: InstallState = .unknown
    @Published var currentStep: PatchStep?
    @Published var completedSteps: Set<PatchStep> = []
    @Published var log: String = ""
    @Published var isPatching = false
    @Published var isPatchComplete = false
    @Published var errorMessage: String?
    @Published var motionVersion: String = ""
    @Published var stockMotionVersion: String = ""
    @Published var bridgeConnected = false
    @Published var isUpdateMode = false
    @Published var currentPanel: WizardPanel = .welcome
    @Published var isSharingCrashLog = false
    @Published var crashShareMessage: String?

    private var launchedProcess: Process?
    private var launchMonitorTask: Task<Void, Never>?

    static let standardApp = "/Applications/Motion.app"

    @Published var sourceApp: String   // path to the stock Motion.app
    let destDir: String                // ~/Applications/MotionKit/
    var moddedApp: String { destDir + "/" + (sourceApp as NSString).lastPathComponent }
    let repoDir: String                // where MotionKit resources live

    /// True when sourceApp points to an existing Motion bundle (standard path or user-browsed).
    var motionFound: Bool { FileManager.default.fileExists(atPath: sourceApp + "/Contents/Info.plist") }

    /// Open a file browser so the user can locate Motion manually.
    func browseForMotion() {
        let panel = NSOpenPanel()
        panel.title = "Locate Motion"
        panel.message = "Select your Motion application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let plistPath = url.appendingPathComponent("Contents/Info.plist").path
        let bundleID = shell("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '\(plistPath)' 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleName = shell("/usr/libexec/PlistBuddy -c 'Print :CFBundleName' '\(plistPath)' 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard bundleID == "com.apple.motionapp" || bundleName.contains("Motion") else {
            errorMessage = "The selected app does not appear to be Motion."
            return
        }

        errorMessage = nil
        sourceApp = url.path
        motionVersion = ""
        checkStatus()
    }

    /// Use Spotlight to find Motion anywhere on the system.
    private static func findMotionViaSpotlight() -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemCFBundleIdentifier == 'com.apple.motionapp'"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let paths = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map(String.init)
        let motionKitDir = NSHomeDirectory() + "/Applications/MotionKit"
        return paths.first { $0.hasPrefix("/Applications/") }
            ?? paths.first { !$0.hasPrefix(motionKitDir) }
    }

    init() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.standardApp) {
            sourceApp = Self.standardApp
        } else {
            sourceApp = Self.standardApp
        }
        destDir = NSHomeDirectory() + "/Applications/MotionKit"

        // The app ships a pre-built dylib in Resources/. No source compilation needed.
        repoDir = Bundle.main.resourcePath ?? NSHomeDirectory() + "/Library/Caches/MotionKit"

        DispatchQueue.main.async { [self] in
            if !motionFound, let found = Self.findMotionViaSpotlight() {
                sourceApp = found
            }
            checkStatus()
            if status != .notInstalled && status != .unknown {
                currentPanel = .complete
            }
        }
    }

    /// Evaluate install state: is MotionKit injected? Is it the current build? Is Motion up to date?
    func checkStatus() {
        let binary = moddedApp + "/Contents/MacOS/Motion"
        let installedFramework = moddedApp + "/Contents/Frameworks/MotionKit.framework"

        stockMotionVersion = readBundleVersion(sourceApp)
        if motionVersion.isEmpty { motionVersion = stockMotionVersion }

        guard FileManager.default.fileExists(atPath: binary) else {
            status = .notInstalled
            bridgeConnected = false
            return
        }
        let otoolResult = shell("otool -L '\(binary)' 2>/dev/null | grep '@rpath/MotionKit'")
        guard !otoolResult.isEmpty else {
            status = .notInstalled
            bridgeConnected = false
            return
        }

        // Bridge check (MotionKit uses port 9878)
        let ps = shell("lsof -i :9878 2>/dev/null | grep LISTEN")
        bridgeConnected = !ps.isEmpty

        let moddedVer = readBundleVersion(moddedApp)
        if !moddedVer.isEmpty { motionVersion = moddedVer }

        if !stockMotionVersion.isEmpty && !moddedVer.isEmpty && stockMotionVersion != moddedVer {
            status = .motionUpdateAvailable
            return
        }

        let installedFrameworkVersion = readBundleVersion(installedFramework)
        let patcherVersion = currentPatcherVersion()
        if !patcherVersion.isEmpty {
            if installedFrameworkVersion.isEmpty || installedFrameworkVersion != patcherVersion {
                status = .updateAvailable
                return
            }
        }

        status = .current
    }

    /// Lightweight poll of the bridge connection state.
    func pollBridgeStatus() async {
        let connected: Bool = await Task.detached {
            let r = shell("lsof -i :9878 2>/dev/null | grep LISTEN")
            return !r.isEmpty
        }.value

        if connected != bridgeConnected {
            bridgeConnected = connected
        }
    }

    /// Bundle the newest Motion crash report together with MotionKit's
    /// own patcher and runtime logs into a single filebin.net bin, then copy
    /// the shareable bin URL to the clipboard.
    func shareLatestCrashLog() {
        guard !isSharingCrashLog else { return }
        isSharingCrashLog = true
        crashShareMessage = "Uploading logs..."
        errorMessage = nil

        Task {
            let result = await uploadSupportLogs()
            await MainActor.run {
                self.isSharingCrashLog = false
                switch result {
                case .success(let shareURL):
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(shareURL, forType: .string)
                    self.crashShareMessage = "Copied to clipboard: \(shareURL)"
                case .failure(let error):
                    self.crashShareMessage = nil
                    self.errorMessage = "Log share failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private nonisolated func uploadSupportLogs() async -> Result<String, Error> {
        var files: [(url: URL, name: String)] = []

        if let crashURL = latestMotionCrashReportURL() {
            files.append((crashURL, crashURL.lastPathComponent))
        }

        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MotionKit")
        let logNames = ["motionkit.log", "motionkit.previous.log",
                        "patcher.log", "patcher.previous.log"]
        for name in logNames {
            let url = logsDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                files.append((url, name))
            }
        }

        guard !files.isEmpty else {
            return .failure(PatchError.msg("No crash report or MotionKit logs found to share."))
        }

        let bin = randomBinID()
        var uploadedCount = 0
        var lastError: Error?

        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: file.url)
            } catch {
                lastError = error
                continue
            }
            let encoded = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.name
            guard let uploadURL = URL(string: "https://filebin.net/\(bin)/\(encoded)") else {
                continue
            }
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(file.name, forHTTPHeaderField: "Filename")
            request.timeoutInterval = 120
            do {
                let (_, response) = try await URLSession.shared.upload(for: request, from: data)
                guard let http = response as? HTTPURLResponse else {
                    lastError = PatchError.msg("Invalid response from filebin.net.")
                    continue
                }
                guard (200...299).contains(http.statusCode) else {
                    lastError = PatchError.msg("filebin.net returned HTTP \(http.statusCode) for \(file.name).")
                    continue
                }
                uploadedCount += 1
            } catch {
                lastError = error
            }
        }

        if uploadedCount == 0 {
            return .failure(lastError ?? PatchError.msg("Upload failed."))
        }
        return .success("https://filebin.net/\(bin)")
    }

    private nonisolated func latestMotionCrashReportURL() -> URL? {
        let fm = FileManager.default
        let directories = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        ]

        var newest: (url: URL, modified: Date)?
        for directory in directories {
            guard let urls = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls {
                let filename = url.lastPathComponent
                guard filename.hasPrefix("Motion"),
                      ["ips", "crash", "txt"].contains(url.pathExtension.lowercased()),
                      let modified = fileModificationDate(at: url) else {
                    continue
                }
                if newest == nil || modified > newest!.modified {
                    newest = (url, modified)
                }
            }
        }
        return newest?.url
    }

    private nonisolated func randomBinID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var id = "motionkit-"
        for _ in 0..<16 { id.append(alphabet.randomElement()!) }
        return id
    }

    func patch() {
        guard !isPatching else { return }
        isPatching = true
        isUpdateMode = false
        isPatchComplete = false
        errorMessage = nil
        log = ""
        completedSteps = []
        currentPanel = .patching

        Task.detached { [self] in
            do {
                try await self.runPatch()
                await MainActor.run {
                    self.isPatchComplete = true
                    self.status = .current
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.appendLog("ERROR: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self.isPatching = false
            }
        }
    }

    func launch() {
        let binary = moddedApp + "/Contents/MacOS/Motion"
        let launchTime = Date()
        let runtimeLog = runtimeLogURL(named: "motionkit.log")
        let logDateBeforeLaunch = fileModificationDate(at: runtimeLog)

        launchMonitorTask?.cancel()
        appendLog("Launching modded Motion...")
        appendLog("Launch binary: \(binary)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleLaunchTermination(
                    process: proc,
                    launchTime: launchTime,
                    logDateBeforeLaunch: logDateBeforeLaunch
                )
            }
        }
        do {
            try process.run()
            launchedProcess = process
            appendLog("Spawned Motion pid \(process.processIdentifier)")
        } catch {
            launchedProcess = nil
            appendLog("Failed to launch Motion: \(error.localizedDescription)")
            return
        }

        launchMonitorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled else { return }
            self.checkStatus()
            if self.bridgeConnected {
                self.appendLog("MotionKit connected on port 9878")
            } else {
                self.appendLog("Bridge not ready after 12s")
                if self.launchedProcess?.isRunning == true {
                    self.appendLog("Motion is still running, but the MotionKit bridge is not listening yet.")
                }
            }
        }
    }

    func uninstall() {
        appendLog("Removing modded Motion...")
        shell("pkill -f 'Applications/MotionKit' 2>/dev/null; sleep 1")
        do {
            try FileManager.default.removeItem(atPath: destDir)
            appendLog("Removed \(destDir)")
            status = .notInstalled
            bridgeConnected = false
            currentPanel = .welcome
        } catch {
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    /// In-place framework update: restage dylib, re-sign. No Motion re-copy needed.
    func updateMotionKit() {
        guard !isPatching else { return }
        isPatching = true
        isUpdateMode = true
        isPatchComplete = false
        errorMessage = nil
        log = ""
        completedSteps = []
        currentPanel = .patching

        Task.detached { [self] in
            do {
                try await self.runUpdate()
                await MainActor.run {
                    self.isPatchComplete = true
                    self.status = .current
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.appendLog("ERROR: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self.isPatching = false
                self.isUpdateMode = false
            }
        }
    }

    /// Delete the modded Motion and re-patch from the current stock Motion.
    func rebuildModdedApp() {
        guard !isPatching else { return }
        appendLog("Removing old modded Motion for rebuild...")
        shell("pkill -f 'Applications/MotionKit' 2>/dev/null; sleep 1")
        try? FileManager.default.removeItem(atPath: moddedApp)
        bridgeConnected = false
        patch()
    }

    // MARK: - Patch Steps

    private nonisolated func runPatch() async throws {
        await setStepAsync(.checkPrereqs)
        if shell("xcode-select -p 2>/dev/null").isEmpty {
            await logAsync("Xcode Command Line Tools not found. Installing...")
            shell("xcode-select --install 2>/dev/null")
            throw PatchError.msg("Xcode Command Line Tools are required.\n\nAn installer window should have appeared. Please complete the installation, then click \"Continue\" again.")
        }
        await logAsync("Xcode tools: OK")

        let sourceApp = await MainActor.run { self.sourceApp }
        let motionVersion = await MainActor.run { self.motionVersion }
        let destDir = await MainActor.run { self.destDir }
        let moddedApp = await MainActor.run { self.moddedApp }

        guard FileManager.default.fileExists(atPath: sourceApp) else {
            throw PatchError.msg("Motion not found at \(sourceApp)")
        }
        await logAsync("Motion \(motionVersion): OK")

        await completeStepAsync(.checkPrereqs)

        await setStepAsync(.copyApp)
        if !FileManager.default.fileExists(atPath: moddedApp) {
            await logAsync("Copying Motion (~2GB, please wait)...")
            let r = shell("mkdir -p '\(destDir)' && cp -R '\(sourceApp)' '\(moddedApp)' 2>&1")
            if !FileManager.default.fileExists(atPath: moddedApp) {
                throw PatchError.msg("Copy failed: \(r)")
            }
            shell("mkdir -p '\(moddedApp)/Contents/_MASReceipt' && cp '\(sourceApp)/Contents/_MASReceipt/receipt' '\(moddedApp)/Contents/_MASReceipt/' 2>/dev/null")
            shell("xattr -cr '\(moddedApp)' 2>/dev/null")
            await logAsync("Copied to \(destDir)")
        } else {
            await logAsync("Using existing copy")
        }
        await completeStepAsync(.copyApp)

        await setStepAsync(.buildDylib)
        let buildDir = NSTemporaryDirectory() + "MotionKit_build"
        shell("mkdir -p '\(buildDir)'")

        let bundledDylib = (Bundle.main.resourcePath ?? "") + "/MotionKit"
        guard FileManager.default.fileExists(atPath: bundledDylib) else {
            throw PatchError.msg("Pre-built MotionKit dylib not found in app bundle. Please re-download the patcher app.")
        }
        await logAsync("Using pre-built MotionKit dylib")
        shell("cp '\(bundledDylib)' '\(buildDir)/MotionKit'")
        await completeStepAsync(.buildDylib)

        await setStepAsync(.installFramework)
        let fwDir = moddedApp + "/Contents/Frameworks/MotionKit.framework"
        shell("""
            mkdir -p '\(fwDir)/Versions/A/Resources'
            cp '\(buildDir)/MotionKit' '\(fwDir)/Versions/A/MotionKit'
            cd '\(fwDir)/Versions' && ln -sf A Current
            cd '\(fwDir)' && ln -sf Versions/Current/MotionKit MotionKit
            cd '\(fwDir)' && ln -sf Versions/Current/Resources Resources
            """)
        let currentVersion = currentPatcherVersion()
        let patcherVersion = currentVersion.isEmpty ? "0.0.0" : currentVersion
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.motionkit.MotionKit</string>
            <key>CFBundleName</key><string>MotionKit</string>
            <key>CFBundleShortVersionString</key><string>\(patcherVersion)</string>
            <key>CFBundleVersion</key><string>\(patcherVersion)</string>
            <key>CFBundlePackageType</key><string>FMWK</string>
            <key>CFBundleExecutable</key><string>MotionKit</string>
            </dict></plist>
            """
        try plist.write(toFile: fwDir + "/Versions/A/Resources/Info.plist", atomically: true, encoding: .utf8)

        await logAsync("Framework installed")
        await completeStepAsync(.installFramework)

        await setStepAsync(.injectDylib)
        let binary = moddedApp + "/Contents/MacOS/Motion"
        let alreadyInjected = shell("otool -L '\(binary)' 2>/dev/null | grep '@rpath/MotionKit'")
        if alreadyInjected.isEmpty {
            let insertDylib = "/tmp/motionkit_insert_dylib"
            if !FileManager.default.fileExists(atPath: insertDylib) {
                await logAsync("Building insert_dylib tool...")
                shell("""
                    cd /tmp && rm -rf _insert_dylib_build && mkdir _insert_dylib_build && cd _insert_dylib_build && \
                    curl -sL https://github.com/tyilo/insert_dylib/archive/refs/heads/master.zip -o insert_dylib.zip && \
                    unzip -qo insert_dylib.zip && \
                    clang -o '\(insertDylib)' insert_dylib-master/insert_dylib/main.c -framework Foundation 2>/dev/null && \
                    cd /tmp && rm -rf _insert_dylib_build
                    """)
            }
            shell("'\(insertDylib)' --inplace --all-yes '@rpath/MotionKit.framework/Versions/A/MotionKit' '\(binary)' 2>&1")
            await logAsync("Injected LC_LOAD_DYLIB")
        } else {
            await logAsync("Already injected (skipping)")
        }
        await completeStepAsync(.injectDylib)

        await setStepAsync(.signApp)
        var signIdentity = preferredSigningIdentity() ?? "-"
        if signIdentity == "-" {
            await logAsync("No local codesigning identity found; using ad-hoc signature (higher risk of macOS launch/security blocks)")
        } else {
            await logAsync("Using signing identity: \(signIdentity)")
        }
        let entitlements = buildDir + "/entitlements.plist"
        let entPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>com.apple.security.app-sandbox</key><false/>
            <key>com.apple.security.cs.disable-library-validation</key><true/>
            <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
            <key>com.apple.security.get-task-allow</key><true/>
            </dict></plist>
            """
        try entPlist.write(toFile: entitlements, atomically: true, encoding: .utf8)

        let quotedIdentity = shellQuote(signIdentity)
        var signResult = shellResult("""
            codesign --force --sign \(quotedIdentity) '\(moddedApp)/Contents/Frameworks/MotionKit.framework' 2>&1 && \
            codesign --force --sign \(quotedIdentity) --entitlements '\(entitlements)' '\(moddedApp)' 2>&1
            """)
        if signResult.status != 0 && signIdentity != "-" {
            await logAsync("Developer signing failed; retrying with ad-hoc signature")
            if !signResult.output.isEmpty {
                await logAsync(String(signResult.output.suffix(400)))
            }
            signIdentity = "-"
            signResult = shellResult("""
                codesign --force --sign - '\(moddedApp)/Contents/Frameworks/MotionKit.framework' 2>&1 && \
                codesign --force --sign - --entitlements '\(entitlements)' '\(moddedApp)' 2>&1
                """)
        }
        guard signResult.status == 0 else {
            throw PatchError.msg("Signing failed:\n\(signResult.output)")
        }
        if signIdentity == "-" {
            await logAsync("Applied ad-hoc signature")
        } else {
            await logAsync("Applied signature: \(signIdentity)")
        }

        let verify = shell("codesign --verify --verbose '\(moddedApp)' 2>&1")
        if verify.contains("valid") || verify.contains("satisfies") {
            await logAsync("Signature verified")
        } else {
            await logAsync("Signature note: \(verify)")
        }
        await completeStepAsync(.signApp)

        await setStepAsync(.setupMCP)
        let repoDir = await MainActor.run { self.repoDir }
        let mcpServer = repoDir + "/mcp/server.py"
        if FileManager.default.fileExists(atPath: mcpServer) {
            await logAsync("MCP server: \(mcpServer)")
        }
        await completeStepAsync(.setupMCP)

        await logAsync("\n--- Post-Patch Diagnostics ---")
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        await logAsync("macOS: \(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)")
        let motionInfo = NSDictionary(contentsOfFile: moddedApp + "/Contents/Info.plist")
        await logAsync("Motion: \(motionInfo?["CFBundleShortVersionString"] ?? "?") (build \(motionInfo?["CFBundleVersion"] ?? "?"))")
        await logAsync("SpliceKit Motion patcher: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        await logAsync("Signing identity used: \(signIdentity)")

        let otoolOut = shell("otool -L '\(moddedApp)/Contents/MacOS/Motion' 2>&1 | grep -i motionkit")
        if otoolOut.isEmpty {
            await logAsync("WARNING: MotionKit load command NOT found in binary (dylib will NOT load)")
        } else {
            await logAsync("Load command: \(otoolOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let fwBinary = moddedApp + "/Contents/Frameworks/MotionKit.framework/Versions/A/MotionKit"
        if FileManager.default.fileExists(atPath: fwBinary) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fwBinary)
            let size = (attrs?[.size] as? Int) ?? 0
            await logAsync("Framework binary: exists (\(size) bytes)")
        } else {
            await logAsync("WARNING: Framework binary NOT found at \(fwBinary)")
        }

        await logAsync("Log saved to: ~/Library/Logs/MotionKit/patcher.log")
        await logAsync("--- End Diagnostics ---")

        await setStepAsync(.done)
        await logAsync("\nSetup complete! You can now launch the enhanced Motion.")
    }

    private nonisolated func runUpdate() async throws {
        let moddedApp = await MainActor.run { self.moddedApp }

        await completeStepAsync(.checkPrereqs)
        await completeStepAsync(.copyApp)

        await setStepAsync(.buildDylib)
        let buildDir = NSTemporaryDirectory() + "MotionKit_build"
        shell("mkdir -p '\(buildDir)'")

        let bundledDylib = (Bundle.main.resourcePath ?? "") + "/MotionKit"
        guard FileManager.default.fileExists(atPath: bundledDylib) else {
            throw PatchError.msg("Pre-built MotionKit dylib not found in app bundle. Please re-download the patcher app.")
        }
        await logAsync("Using pre-built MotionKit dylib")
        shell("cp '\(bundledDylib)' '\(buildDir)/MotionKit'")
        await completeStepAsync(.buildDylib)

        await setStepAsync(.installFramework)
        let fwDir = moddedApp + "/Contents/Frameworks/MotionKit.framework"
        shell("cp '\(buildDir)/MotionKit' '\(fwDir)/Versions/A/MotionKit'")

        let currentVersion = currentPatcherVersion()
        let patcherVersion = currentVersion.isEmpty ? "0.0.0" : currentVersion
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.motionkit.MotionKit</string>
            <key>CFBundleName</key><string>MotionKit</string>
            <key>CFBundleShortVersionString</key><string>\(patcherVersion)</string>
            <key>CFBundleVersion</key><string>\(patcherVersion)</string>
            <key>CFBundlePackageType</key><string>FMWK</string>
            <key>CFBundleExecutable</key><string>MotionKit</string>
            </dict></plist>
            """
        try plist.write(toFile: fwDir + "/Versions/A/Resources/Info.plist", atomically: true, encoding: .utf8)

        await logAsync("Framework updated")
        await completeStepAsync(.installFramework)
        await completeStepAsync(.injectDylib)

        await setStepAsync(.signApp)
        var signIdentity = preferredSigningIdentity() ?? "-"
        if signIdentity == "-" {
            await logAsync("No local codesigning identity found; using ad-hoc signature")
        } else {
            await logAsync("Using signing identity: \(signIdentity)")
        }
        let entitlements = buildDir + "/entitlements.plist"
        let entPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>com.apple.security.app-sandbox</key><false/>
            <key>com.apple.security.cs.disable-library-validation</key><true/>
            <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
            <key>com.apple.security.get-task-allow</key><true/>
            </dict></plist>
            """
        try entPlist.write(toFile: entitlements, atomically: true, encoding: .utf8)

        let quotedIdentity = shellQuote(signIdentity)
        var signResult = shellResult("""
            codesign --force --sign \(quotedIdentity) '\(moddedApp)/Contents/Frameworks/MotionKit.framework' 2>&1 && \
            codesign --force --sign \(quotedIdentity) --entitlements '\(entitlements)' '\(moddedApp)' 2>&1
            """)
        if signResult.status != 0 && signIdentity != "-" {
            await logAsync("Developer signing failed; retrying with ad-hoc signature")
            signIdentity = "-"
            signResult = shellResult("""
                codesign --force --sign - '\(moddedApp)/Contents/Frameworks/MotionKit.framework' 2>&1 && \
                codesign --force --sign - --entitlements '\(entitlements)' '\(moddedApp)' 2>&1
                """)
        }
        guard signResult.status == 0 else {
            throw PatchError.msg("Signing failed:\n\(signResult.output)")
        }

        let verify = shell("codesign --verify --verbose '\(moddedApp)' 2>&1")
        if verify.contains("valid") || verify.contains("satisfies") {
            await logAsync("Signature verified")
        }
        await completeStepAsync(.signApp)
        await completeStepAsync(.setupMCP)

        await setStepAsync(.done)
        await logAsync("\nMotionKit updated! You can now launch Motion.")
    }

    // MARK: - Helpers

    private nonisolated func runtimeLogURL(named name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MotionKit")
            .appendingPathComponent(name)
    }

    private nonisolated func fileModificationDate(at url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private nonisolated func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func handleLaunchTermination(process: Process,
                                         launchTime: Date,
                                         logDateBeforeLaunch: Date?) {
        let runtime = Date().timeIntervalSince(launchTime)
        let reason: String
        switch process.terminationReason {
        case .exit:
            reason = "exit"
        case .uncaughtSignal:
            reason = "signal"
        @unknown default:
            reason = "unknown"
        }

        appendLog(String(format: "Motion process %d terminated after %.1fs (%@ %d)",
                         process.processIdentifier,
                         runtime,
                         reason,
                         process.terminationStatus))
        if launchedProcess?.processIdentifier == process.processIdentifier {
            launchedProcess = nil
            launchMonitorTask?.cancel()
            launchMonitorTask = nil
        }
    }

    private nonisolated func currentPatcherVersion() -> String {
        if let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !shortVersion.isEmpty {
            return shortVersion
        }
        if let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !buildVersion.isEmpty {
            return buildVersion
        }
        return ""
    }

    func appendLog(_ text: String) {
        log += text + "\n"
        patcherLogWrite(text)
    }

    private nonisolated func logAsync(_ text: String) async {
        patcherLogWrite(text)
        await MainActor.run { self.log += text + "\n" }
    }

    private nonisolated func setStepAsync(_ step: PatchStep) async {
        await MainActor.run { self.currentStep = step }
    }

    private nonisolated func completeStepAsync(_ step: PatchStep) async {
        await MainActor.run { _ = self.completedSteps.insert(step) }
    }
}
