import Foundation
import Synchronization

struct CommandResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !timedOut }

    /// Ultime righe non vuote dell'output (per il registro: solo metadati operativi).
    func tail(_ lines: Int = 4) -> String {
        let all = (stdout + "\n" + stderr)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return all.suffix(lines).joined(separator: "\n")
    }
}

enum CommandError: Error, LocalizedError {
    case notExecutable(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notExecutable(let path): "\(path) non è un eseguibile valido."
        case .launchFailed(let message): "Impossibile avviare il comando: \(message)"
        }
    }
}

/// Comandi esterni consentiti. Ogni caso produce argomenti fissi: nessun input viene
/// interpolato in una shell e non esistono comandi "liberi".
enum AllowedCommand: Sendable, Hashable {
    case pnpmVersion
    case pnpmStorePath
    case pnpmStorePrune
    case simctlListDevices
    case simctlDeleteUnavailable
    case simctlRuntimeList
    case diskutilAPFSList
    case tmutilLocalSnapshots
    case processList(columns: ProcessColumns)
    case loginShellPath

    enum ProcessColumns: String, Sendable, Hashable {
        case executable = "comm="
        case commandLine = "args="
    }

    static let pathMarkerStart = "__MACCARE_PATH_START__"
    static let pathMarkerEnd = "__MACCARE_PATH_END__"

    var arguments: [String] {
        switch self {
        case .pnpmVersion: ["--version"]
        case .pnpmStorePath: ["store", "path"]
        case .pnpmStorePrune: ["store", "prune"]
        case .simctlListDevices: ["simctl", "list", "devices", "--json"]
        case .simctlDeleteUnavailable: ["simctl", "delete", "unavailable"]
        case .simctlRuntimeList: ["simctl", "runtime", "list", "-j"]
        case .diskutilAPFSList: ["apfs", "list", "-plist"]
        case .tmutilLocalSnapshots: ["listlocalsnapshots", "/"]
        case .processList(let columns): ["-A", "-ww", "-o", columns.rawValue]
        case .loginShellPath:
            ["-l", "-i", "-c", "printf '%s%s%s' '\(Self.pathMarkerStart)' \"$PATH\" '\(Self.pathMarkerEnd)'"]
        }
    }

    /// Eseguibili ammessi per ciascun comando (verificati sul nome del file).
    var allowedExecutableNames: Set<String> {
        switch self {
        case .pnpmVersion, .pnpmStorePath, .pnpmStorePrune: ["pnpm"]
        case .simctlListDevices, .simctlDeleteUnavailable, .simctlRuntimeList: ["xcrun"]
        case .diskutilAPFSList: ["diskutil"]
        case .tmutilLocalSnapshots: ["tmutil"]
        case .processList: ["ps"]
        case .loginShellPath: ["zsh", "bash"]
        }
    }
}

private final class OutputBuffer: Sendable {
    private let storage = Mutex(Data())
    private let limit: Int

    init(limit: Int = 4 * 1024 * 1024) { self.limit = limit }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        storage.withLock { buffer in
            if buffer.count < limit { buffer.append(data.prefix(limit - buffer.count)) }
        }
    }

    var string: String {
        storage.withLock { String(decoding: $0, as: UTF8.self) }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    let timedOut = Atomic<Bool>(false)
}

enum CommandRunner {
    static func run(
        _ command: AllowedCommand,
        executable: URL,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration
    ) async throws -> CommandResult {
        let path = executable.path
        guard command.allowedExecutableNames.contains(executable.lastPathComponent) else {
            throw CommandError.notExecutable(path)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CommandError.notExecutable(path)
        }

        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = command.arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let outBuffer = OutputBuffer()
        let errBuffer = OutputBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { finished in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    errBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: CommandResult(
                        exitCode: finished.terminationStatus,
                        stdout: outBuffer.string,
                        stderr: errBuffer.string,
                        timedOut: box.timedOut.load(ordering: .relaxed)
                    ))
                }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CommandError.launchFailed(error.localizedDescription))
                    return
                }
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    if box.process.isRunning {
                        box.timedOut.store(true, ordering: .relaxed)
                        box.process.terminate()
                    }
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}
