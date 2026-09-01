import Foundation

enum ProcessRun {
    @discardableResult
    static func run(
        _ launchPath: String,
        arguments: [String],
        timeout: TimeInterval = 20
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = CollectedOutput()
        out.fileHandleForReading.readabilityHandler = { handle in
            collected.append(stdout: handle.availableData)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            collected.append(stderr: handle.availableData)
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw NSError(
                domain: "anny",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "命令超时"]
            )
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.append(stdout: out.fileHandleForReading.readDataToEndOfFile())
        collected.append(stderr: err.fileHandleForReading.readDataToEndOfFile())

        let (stdoutData, stderrData) = collected.snapshot()
        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    static func which(_ name: String) -> String? {
        var paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            NSHomeDirectory() + "/.local/bin/\(name)",
        ]
        if name == "tailscale" {
            paths.insert("/Applications/Tailscale.app/Contents/MacOS/Tailscale", at: 0)
        }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func append(stdout chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        stdout.append(chunk)
        lock.unlock()
    }

    func append(stderr chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        stderr.append(chunk)
        lock.unlock()
    }

    func snapshot() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}
