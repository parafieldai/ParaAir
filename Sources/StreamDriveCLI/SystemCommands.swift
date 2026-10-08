import Foundation
import Darwin

struct ProcessOutput {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

enum SystemCommands {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 30) throws -> ProcessOutput {
        guard executable.hasPrefix("/"), timeout.isFinite, timeout > 0 else {
            throw CLIUsageError(message: "Native commands require an absolute executable path and a positive deadline")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let stdout = BoundedOutput(), stderr = BoundedOutput()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { stdout.consume(output.fileHandleForReading); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { stderr.consume(errors.fileHandleForReading); readers.leave() }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
        }
        process.waitUntilExit()
        if readers.wait(timeout: .now() + 1) == .timedOut {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            throw CLIUsageError(message: "Native command output exceeded its deadline")
        }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        if timedOut { throw CLIUsageError(message: "Native command exceeded its deadline") }
        return ProcessOutput(exitCode: process.terminationStatus, stdout: stdout.string, stderr: stderr.string)
    }

    private final class BoundedOutput {
        private let lock = NSLock()
        private var data = Data()
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        func consume(_ file: FileHandle) {
            var captured = Data()
            while let next = try? file.read(upToCount: 65_536), !next.isEmpty {
                if captured.count < 1_048_576 { captured.append(next.prefix(1_048_576 - captured.count)) }
            }
            lock.lock(); data = captured; lock.unlock()
        }
    }
}

enum MountController {
    static func mountArguments(profile: String, stateRoot: String, mountPoint: String) -> [String] {
        ["-F", "-t", "streamdrive", "-o", "nosuid,nodev,-p=\(profile)", stateRoot, mountPoint]
    }

    static func mountedVolumes() -> [MountedVolume] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        return (0..<Int(count)).map { index in
            var entry = mounts[index]
            let path = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let type = withUnsafePointer(to: &entry.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
            }
            return MountedVolume(mountPoint: path, type: type)
        }
    }
}

struct MountedVolume: Equatable {
    var mountPoint: String
    var type: String
    var isStreamDrive: Bool { type.lowercased() == "streamdrive" }
}
