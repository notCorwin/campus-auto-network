import Darwin
import Dispatch
import Foundation
import Network

final class RunCoordinator {
    private let binary: URL
    private let queue = DispatchQueue(label: "com.nowaywastaken.csustautologin.monitor")
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var timer: DispatchSourceTimer?
    private var process: Process?
    private var pending = false
    private var scheduled = false
    private var stopping = false

    init(binaryPath: String) {
        binary = URL(fileURLWithPath: binaryPath)
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.requestRun()
        }
        monitor.start(queue: queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .seconds(60),
            repeating: .seconds(60),
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            self?.requestRun()
        }
        timer.resume()
        self.timer = timer
        requestRun()
    }

    func requestRun() {
        queue.async { [weak self] in
            self?.scheduleRun()
        }
    }

    private func scheduleRun() {
        guard !stopping else { return }
        pending = true
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self else { return }
            scheduled = false
            startPendingRun()
        }
    }

    private func startPendingRun() {
        guard !stopping, pending, process == nil else { return }
        pending = false

        let child = Process()
        child.executableURL = binary
        child.arguments = ["run"]
        child.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        child.standardError = FileHandle.standardError
        child.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.process = nil
                if self.pending {
                    self.scheduleRun()
                }
            }
        }

        do {
            try child.run()
            process = child
        } catch {
            fputs("无法启动自动登录程序：\(error)\n", stderr)
        }
    }

    func stop() {
        queue.sync {
            stopping = true
            monitor.cancel()
            timer?.cancel()
            process?.terminate()
        }
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("用法：csust-auto-login-monitor <csust-auto-login 路径>\n", stderr)
    exit(64)
}

let binaryPath = CommandLine.arguments[1]
guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
    fputs("自动登录程序不可执行：\(binaryPath)\n", stderr)
    exit(EXIT_FAILURE)
}

let coordinator = RunCoordinator(binaryPath: binaryPath)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    coordinator.stop()
    exit(EXIT_SUCCESS)
}
termination.resume()

let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    coordinator.stop()
    exit(EXIT_SUCCESS)
}
interrupt.resume()

coordinator.start()
dispatchMain()
