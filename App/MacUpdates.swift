#if os(macOS) && M0_DISTRIBUTION
import AppKit
import SwiftUI

/// Sparkle runs in a separately signed helper. A private pipe ties its lifetime to this app.
@MainActor
final class MacUpdates: ObservableObject {
    private let executable = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/Update.app/Contents/MacOS/Update")
    private var helper: Process?
    private var input: FileHandle?
    private var requestedCheck = false
    @Published var automatic = UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks") {
        didSet {
            guard automatic != oldValue else { return }
            UserDefaults.standard.set(automatic, forKey: "SUEnableAutomaticChecks")
            if automatic || helper?.isRunning == true { send(automatic ? "Y" : "N") }
        }
    }

    var available: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    func startIfEnabled() {
        if available && automatic && helper?.isRunning != true { send("Y") }
    }

    func check() {
        requestedCheck = true
        send("C")
    }

    private func send(_ command: String) {
        do {
            if helper?.isRunning != true {
                let process = Process()
                process.executableURL = executable
                let pipe = Pipe()
                guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                process.standardInput = pipe
                process.terminationHandler = { [weak self] finished in
                    Task { @MainActor in
                        guard let self, self.helper === finished else { return }
                        self.input = nil
                        self.helper = nil
                        if self.requestedCheck && finished.terminationStatus != 0 { self.showFailure() }
                        self.requestedCheck = false
                    }
                }
                try process.run()
                helper = process
                input = pipe.fileHandleForWriting
            }
            try input?.write(contentsOf: Data(command.utf8))
        } catch {
            if requestedCheck { showFailure() }
            requestedCheck = false
        }
    }

    private func showFailure() {
        let alert = NSAlert()
        alert.messageText = "无法启动更新助手"
        alert.informativeText = "请重新打开应用后再检查更新。"
        alert.runModal()
    }
}
#endif
