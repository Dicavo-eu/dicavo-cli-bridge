import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct AnalysisCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let standardInput: Data
    let currentDirectoryURL: URL
    let timeout: Duration
}

struct AnalysisCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol AnalysisCommandRunning: Sendable {
    func run(_ command: AnalysisCommand, tool: AnalysisTool) async throws
        -> AnalysisCommandResult
}

// `Process` exists only on macOS. The protocol above is portable, so a
// platform without subprocesses can still express "no runner" rather
// than losing the analysis types entirely.
#if os(macOS)
struct AnalysisProcessRunner: AnalysisCommandRunning {
    private let maximumCapturedBytes: Int
    private let terminationGracePeriod: TimeInterval

    init(
        maximumCapturedBytes: Int = 1_100_000,
        terminationGracePeriod: TimeInterval = 2
    ) {
        self.maximumCapturedBytes = max(1_024, maximumCapturedBytes)
        self.terminationGracePeriod = max(0, terminationGracePeriod)
    }

    func run(
        _ command: AnalysisCommand,
        tool: AnalysisTool
    ) async throws -> AnalysisCommandResult {
        let controller = ProcessController(
            terminationGracePeriod: terminationGracePeriod
        )
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: AnalysisCommandResult.self) { group in
                group.addTask {
                    try await execute(
                        command,
                        tool: tool,
                        controller: controller,
                        maximumCapturedBytes: maximumCapturedBytes
                    )
                }
                group.addTask {
                    try await ContinuousClock().sleep(for: command.timeout)
                    controller.timeOut()
                    throw AnalysisError.processTimedOut(tool: tool)
                }
                defer { group.cancelAll() }
                while let next = await group.nextResult() {
                    switch next {
                    case .success(let result):
                        try Task.checkCancellation()
                        // The child the timeout stopped can exit, and its
                        // result arrive, before the timeout's own error does:
                        // the run still timed out, it did not end with the
                        // signal's exit code.
                        if controller.hasTimedOut {
                            throw AnalysisError.processTimedOut(tool: tool)
                        }
                        return result
                    case .failure(let error):
                        // A timeout that came once the child had finished
                        // stopped nothing; the child's result is next.
                        if error as? AnalysisError == .processTimedOut(tool: tool), !controller.hasTimedOut {
                            continue
                        }
                        throw error
                    }
                }
                throw CancellationError()
            }
        } onCancel: {
            controller.requestTermination()
        }
    }

    private func execute(
        _ command: AnalysisCommand,
        tool: AnalysisTool,
        controller: ProcessController,
        maximumCapturedBytes: Int
    ) async throws -> AnalysisCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            // Antigravity's NDJSON carries the structured output in the LAST
            // `result` line, which repeats it whole; keeping the head of a
            // long stream would lose it and fail a successful run. Keep the
            // newest bytes for it, with a wider floor of 4 MB.
            let output = CappedDataBuffer(
                limit: tool == .antigravity
                    ? max(maximumCapturedBytes, 4_000_000)
                    : maximumCapturedBytes,
                retention: tool == .antigravity ? .tail : .head
            )
            let errors = CappedDataBuffer(limit: maximumCapturedBytes)

            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.currentDirectoryURL = command.currentDirectoryURL
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            #if canImport(Darwin)
            // A cancellation can close this owned writer while the input is
            // still being copied. Convert the resulting broken pipe into an
            // error instead of delivering SIGPIPE to the test/app process.
            _ = Darwin.fcntl(
                inputPipe.fileHandleForWriting.fileDescriptor,
                F_SETNOSIGPIPE,
                1
            )
            #endif

            controller.attach(process, inputWriter: inputPipe.fileHandleForWriting)

            do {
                try process.run()
                controller.establishOwnedProcessGroup(for: process)
                controller.terminateIfRequested(process)
            } catch {
                controller.detach(process)
                throw AnalysisError.processLaunchFailed(
                    tool: tool,
                    message: error.localizedDescription
                )
            }

            // Started only once the child exists, so a launch failure has
            // nothing to join. Both pipes are drained at the same time: a tool
            // that fills one while the parent reads only the other would block
            // forever.
            let readers = PipeDrain.start([
                (outputPipe.fileHandleForReading, output),
                (errorPipe.fileHandleForReading, errors),
            ])

            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: command.standardInput)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                // A tool that rejects its arguments or is signed out exits before
                // draining stdin, which breaks this pipe. That is the tool's own
                // failure, so close the writer and let the normal result path
                // report its exit code and stderr instead of a launch failure.
                if Self.isBrokenPipe(error), !controller.isTerminationRequested {
                    try? inputPipe.fileHandleForWriting.close()
                } else {
                    controller.terminateAfterInputFailure(process)
                    process.waitUntilExit()
                    readers.wait(for: process, controller: controller, isTerminating: { true })
                    controller.detach(process)
                    if controller.isTerminationRequested {
                        throw CancellationError()
                    }
                    throw AnalysisError.processLaunchFailed(
                        tool: tool,
                        message: error.localizedDescription
                    )
                }
            }

            process.waitUntilExit()
            // Every byte is already in the buffers once the readers have seen
            // EOF; there is deliberately no second read of either descriptor
            // here, and a run being stopped does not wait for a descendant
            // that keeps the pipes open.
            readers.wait(for: process, controller: controller, isTerminating: { controller.isTerminationRequested })
            controller.detach(process)

            return AnalysisCommandResult(
                exitCode: process.terminationStatus,
                standardOutput: output.value,
                standardError: errors.value
            )
        }.value
    }

    /// `F_SETNOSIGPIPE` turns a broken pipe into a thrown error whose POSIX
    /// cause is wrapped in an opaque Cocoa write error, so inspect the chain.
    private static func isBrokenPipe(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSPOSIXErrorDomain, candidate.code == Int(EPIPE) {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

/// Every child the runner started and has not yet seen exit, by the target
/// a signal goes to: the negative group ID where the child leads a group of
/// its own, else its PID. A bridge that quits cannot rely on the delayed
/// SIGKILL of a cancelled run, because the process is gone before it fires;
/// `terminateAll` makes sure no tool outlives it.
enum RunningAnalysisProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var targets: [ObjectIdentifier: pid_t] = [:]

    static func register(_ owner: AnyObject, target: pid_t) {
        lock.withLock { targets[ObjectIdentifier(owner)] = target }
    }

    static func unregister(_ owner: AnyObject) {
        _ = lock.withLock { targets.removeValue(forKey: ObjectIdentifier(owner)) }
    }

    static var count: Int { lock.withLock { targets.count } }

    /// SIGTERM to every child and its group, up to `gracePeriod` for them
    /// to go, then SIGKILL to whatever is left. Blocks the caller meanwhile.
    static func terminateAll(gracePeriod: TimeInterval) {
        #if canImport(Darwin)
        var remaining = Set(lock.withLock { targets.values })
        guard !remaining.isEmpty else { return }
        for target in remaining { _ = Darwin.kill(target, SIGTERM) }
        let deadline = Date().addingTimeInterval(max(0, gracePeriod))
        while !remaining.isEmpty, Date() < deadline {
            remaining = remaining.filter { Darwin.kill($0, 0) == 0 }
            if !remaining.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        for target in remaining { _ = Darwin.kill(target, SIGKILL) }
        #endif
    }
}

/// Coordinates one process launched by this runner. A pending cancellation is
/// retained until after `Process.run()`, so cancellation before launch cannot
/// leave a new child behind. The owned stdin writer is closed before sending a
/// signal, which unblocks a write when a tool is not reading its input.
private final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    let terminationGracePeriod: TimeInterval
    private var process: Process?
    private var inputWriter: FileHandle?
    private var shouldTerminate = false
    private var timedOut = false
    /// Set once the child has exited and its output is read: a timeout
    /// after that stopped nothing.
    private var finished = false
    private var processGroupID: pid_t?

    init(terminationGracePeriod: TimeInterval) {
        self.terminationGracePeriod = max(0, terminationGracePeriod)
    }

    func attach(_ process: Process, inputWriter: FileHandle) {
        lock.lock()
        self.process = process
        self.inputWriter = inputWriter
        let requiresTermination = shouldTerminate
        lock.unlock()
        if requiresTermination { terminate(process) }
    }

    func detach(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
            inputWriter = nil
            processGroupID = nil
            finished = true
        }
        lock.unlock()
        RunningAnalysisProcesses.unregister(self)
    }

    /// Foundation already starts the child as the leader of a process group
    /// of its own, which is also why `setpgid` after launch fails with
    /// EACCES: the child has called exec by then. That group is the one
    /// signalled; where the child is not its leader, one is made if macOS
    /// still allows it, and failing both only the direct child is signalled.
    func establishOwnedProcessGroup(for process: Process) {
        #if canImport(Darwin)
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let leadsItsGroup = Darwin.getpgid(pid) == pid || Darwin.setpgid(pid, pid) == 0
        // Never this process's own group: a negative PID would signal it.
        guard leadsItsGroup, pid != Darwin.getpgrp() else {
            RunningAnalysisProcesses.register(self, target: pid)
            return
        }
        lock.lock()
        if self.process === process { processGroupID = pid }
        lock.unlock()
        RunningAnalysisProcesses.register(self, target: -pid)
        #endif
    }

    func terminateIfRequested(_ process: Process) {
        lock.lock()
        let terminate = shouldTerminate && self.process === process
        lock.unlock()
        if terminate { self.terminate(process) }
    }

    var isTerminationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldTerminate
    }

    var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    /// Stops the child because its time ran out, remembered before the
    /// signal goes so the run reports the timeout whichever result comes
    /// first. A child that finished just before is not timed out: its
    /// result stands.
    func timeOut() {
        lock.lock()
        timedOut = !finished
        lock.unlock()
        requestTermination()
    }

    func requestTermination() {
        lock.lock()
        shouldTerminate = true
        let runningProcess = process
        let inputWriter = inputWriter
        lock.unlock()
        try? inputWriter?.close()
        terminate(runningProcess)
    }

    func terminateAfterInputFailure(_ process: Process) {
        lock.lock()
        let inputWriter = self.process === process ? inputWriter : nil
        lock.unlock()
        try? inputWriter?.close()
        terminate(process)
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        signal(.term, to: process)
        DispatchQueue.global().asyncAfter(
            deadline: .now() + terminationGracePeriod
        ) { [weak self, weak process] in
            self?.forceKillIfStillOwned(process)
        }
    }

    private func forceKillIfStillOwned(_ process: Process?) {
        guard let process, process.isRunning else { return }
        lock.lock()
        let isOwned = self.process === process
        lock.unlock()
        guard isOwned else { return }
        signal(.kill, to: process)
    }

    /// Signals what is left of the child's group once the child itself has
    /// exited: a descendant that still holds its pipes. Only the group
    /// established for this child, and only while it is still attached.
    func signalRemainingGroup(of process: Process, kill: Bool) {
        #if canImport(Darwin)
        lock.lock()
        let groupID = self.process === process ? processGroupID : nil
        lock.unlock()
        guard let groupID, groupID > 0 else { return }
        _ = Darwin.kill(-groupID, kill ? SIGKILL : SIGTERM)
        #endif
    }

    private enum Signal {
        case term
        case kill
    }

    private func signal(_ signal: Signal, to process: Process) {
        #if canImport(Darwin)
        lock.lock()
        let groupID = self.process === process ? processGroupID : nil
        lock.unlock()
        let value: Int32 = signal == .term ? SIGTERM : SIGKILL
        if let groupID, groupID > 0 {
            // A negative PID targets only the group we established for this
            // child, including descendants that inherited its stdio pipes.
            _ = Darwin.kill(-groupID, value)
        } else {
            _ = Darwin.kill(process.processIdentifier, value)
        }
        #else
        process.terminate()
        #endif
    }
}

/// Reads each pipe to EOF on its own thread, with exactly one reader per
/// descriptor.
///
/// The previous shape was a `readabilityHandler` plus a
/// `readDataToEndOfFile()` once the handler had been cleared. Clearing a
/// handler does not cancel an invocation already dispatched on Foundation's
/// private IO queue, so for that window two readers were pulling from the
/// same descriptor. Both appended into the same buffer under its lock, so
/// nothing was corrupted — but the order of the appends was whatever the
/// scheduler chose, and captured output could come back reassembled out of
/// order. It surfaced as a rare CI failure on the one assertion that compares
/// stdout exactly: a fourteen-byte `--version` string split across two reads.
///
/// Reading continues past the buffer's cap. The buffer discards the excess,
/// but the pipe still has to be drained or the child blocks writing into it.
private final class PipeDrain: @unchecked Sendable {
    private let group = DispatchGroup()

    static func start(_ pipes: [(FileHandle, CappedDataBuffer)]) -> PipeDrain {
        let drain = PipeDrain()
        for (handle, buffer) in pipes {
            drain.group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { drain.group.leave() }
                while true {
                    let chunk = handle.availableData
                    // `availableData` blocks until there is something to read
                    // and returns empty exactly at end of file.
                    guard !chunk.isEmpty else { return }
                    buffer.append(chunk)
                }
            }
        }
        return drain
    }

    /// Blocks until both pipes have reached end of file. The child's exit
    /// does not guarantee that on its own: a descendant it started holds the
    /// same pipes for as long as it lives. Once `isTerminating` says the run
    /// is being stopped the wait is bounded — what is left of the child's
    /// group gets SIGTERM, then SIGKILL after the grace period, and a reader
    /// still blocked after that is abandoned rather than waited for.
    func wait(
        for process: Process,
        controller: ProcessController,
        isTerminating: () -> Bool
    ) {
        while group.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            guard isTerminating() else { continue }
            controller.signalRemainingGroup(of: process, kill: false)
            if group.wait(timeout: .now() + controller.terminationGracePeriod) == .success { return }
            controller.signalRemainingGroup(of: process, kill: true)
            _ = group.wait(timeout: .now() + .seconds(1))
            return
        }
    }
}

final class CappedDataBuffer: @unchecked Sendable {
    /// Which end of the stream survives the cap. Head-first keeps the
    /// beginning; tail-first drops from the front so the newest bytes —
    /// for NDJSON tools, the final `result` line — are still there.
    enum Retention {
        case head
        case tail
    }

    private let lock = NSLock()
    private let limit: Int
    private let retention: Retention
    private var data = Data()

    init(limit: Int, retention: Retention = .head) {
        self.limit = limit
        self.retention = retention
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        switch retention {
        case .head:
            if data.count < limit {
                data.append(newData.prefix(limit - data.count))
            }
        case .tail:
            data.append(newData)
            if data.count > limit {
                data.removeFirst(data.count - limit)
            }
        }
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
#endif

/// A platform that cannot start a subprocess still needs a value of this
/// type, so the analysis layer keeps one shape everywhere. It fails loudly
/// and never reaches for a network provider instead.
#if !os(macOS)
struct UnavailableAnalysisCommandRunner: AnalysisCommandRunning {
    func run(
        _ command: AnalysisCommand,
        tool: AnalysisTool
    ) async throws -> AnalysisCommandResult {
        throw AnalysisError.localToolUnavailableOnThisPlatform
    }
}
#endif

extension CLIAnalysisProvider {
    /// The runner this platform can actually provide.
    static func defaultRunner() -> any AnalysisCommandRunning {
        #if os(macOS)
        AnalysisProcessRunner()
        #else
        UnavailableAnalysisCommandRunner()
        #endif
    }
}

// Where a locally installed CLI tool lives is a macOS filesystem
// question, and the home directory it starts from is not available on
// other platforms. Only the macOS application resolves an executable.
#if os(macOS)
enum AnalysisExecutableResolver {
    static func resolve(tool: AnalysisTool, configuredPath: String) -> URL? {
        let normalized = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            let configuredURL = URL(fileURLWithPath: normalized).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: configuredURL.path)
                ? configuredURL
                : nil
        }

        return candidates(for: tool).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func candidates(for tool: AnalysisTool) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [String]
        switch tool {
        case .codex:
            paths = [
                // ChatGPT.app ships Codex as a bundle; `bin/codex` is the
                // entrypoint its `codex-package.json` names. Earlier
                // releases kept the binary directly in Resources.
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                home.appendingPathComponent(".local/bin/codex").path,
            ]
        case .claude:
            paths = [
                home.appendingPathComponent(".local/bin/claude").path,
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
        case .antigravity:
            paths = [
                home.appendingPathComponent(".local/bin/agy").path,
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy",
            ]
        case .appleIntelligence, .claudeAPI, .openAICompatibleAPI, .dicavoBridge, .localCommand, .unrecognized:
            // Not command-line tools, or (the local command) one whose path
            // is configured in the bridge: nothing on disk to look for.
            return []
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0))
                    .appendingPathComponent(tool.executableName)
                    .path
            }
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}

/// agy keeps every run it has ever done. These are the files a run leaves
/// behind that are named by its conversation id; the prompt text itself
/// lives in `conversations` and `brain`. A generated title in agy's
/// summaries cannot be removed and is disclosed in Settings.
enum AntigravityRunCleanup {
    static func removeRun(
        conversationID: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        // The id builds file paths, so only an exact UUID passes on.
        guard conversationID.range(
            of: #"^[0-9a-fA-F-]{36}$"#,
            options: .regularExpression
        ) != nil else { return }
        let root = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let brain = root.appendingPathComponent("brain/\(conversationID)", isDirectory: true)
        let paths = [
            root.appendingPathComponent("conversations/\(conversationID).db"),
            root.appendingPathComponent("conversations/\(conversationID).db-wal"),
            root.appendingPathComponent("conversations/\(conversationID).db-shm"),
            brain,
            root.appendingPathComponent("annotations/\(conversationID).pbtxt"),
            root.appendingPathComponent("presence/\(conversationID).lock"),
        ]
        // Removing a missing file throws and is ignored; other failures are
        // not worth failing the analysis over.
        for path in paths {
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// The last conversation agy ran in this directory, from its cache map of
    /// working-directory paths to conversation ids. A failed run reaches no
    /// stdout to parse, and this map is what still names its files: every
    /// analysis runs in its own fresh temporary directory, so an entry for
    /// that path can only be this run.
    static func conversationID(
        forWorkingDirectory directory: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let url = home.appendingPathComponent(
            ".gemini/antigravity-cli/cache/last_conversations.json"
        )
        guard let data = try? Data(contentsOf: url), data.count <= 1_000_000,
              let conversations = try? JSONDecoder().decode(
                  [String: String].self, from: data
              )
        else { return nil }
        // agy records the resolved path (/private/var/...), which differs
        // from the one FileManager hands out (/var/...); try each spelling.
        var candidates = [directory.path, directory.resolvingSymlinksInPath().path]
        if directory.path.hasPrefix("/private") {
            candidates.append(String(directory.path.dropFirst("/private".count)))
        } else {
            candidates.append("/private" + directory.path)
        }
        return candidates.lazy.compactMap { conversations[$0] }.first
    }
}
#endif

enum AnalysisToolStatus: Equatable, Sendable {
    case unknown
    case unavailable
    case available(path: String, version: String?)
    case authenticationRequired(path: String, version: String?, loginCommand: String)
    case failed(path: String, reason: String)
}

enum AnalysisAuthenticationStatus: Equatable, Sendable {
    case authenticated
    case authenticationRequired
}

struct CLIAnalysisProvider: Sendable {
    static let defaultRequestTimeout: Duration = .seconds(600)

    let tool: AnalysisTool
    let executableURL: URL
    let model: String?
    let runner: any AnalysisCommandRunning
    let requestTimeout: Duration

    init(
        tool: AnalysisTool,
        executableURL: URL,
        model: String? = nil,
        runner: any AnalysisCommandRunning = CLIAnalysisProvider.defaultRunner(),
        requestTimeout: Duration = Self.defaultRequestTimeout
    ) {
        self.tool = tool
        self.executableURL = executableURL
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = normalizedModel?.isEmpty == false ? normalizedModel : nil
        self.runner = runner
        self.requestTimeout = requestTimeout
    }

    /// Runs one prompt through the tool and returns the Markdown it produced,
    /// exactly as the tool's structured transport carried it. Validation
    /// against Dicavo's reserved markers happens in `analyze(_:)`; the bridge
    /// calls this directly and leaves validation to the Dicavo that asked.
    func rawMarkdown(forPromptText promptText: String) async throws -> String {
        try requireExecutable()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let schemaData = try JSONSerialization.data(
            withJSONObject: AnalysisTransport.schema,
            options: [.sortedKeys]
        )
        let schemaURL = temporaryDirectory.appendingPathComponent("analysis-schema.json")
        try writePrivate(schemaData, to: schemaURL)

        let responseURL = temporaryDirectory.appendingPathComponent("analysis-response.json")
        let arguments = arguments(
            schemaData: schemaData,
            schemaURL: schemaURL,
            responseURL: responseURL
        )
        var standardInput = Data(promptText.utf8)
        if tool == .antigravity {
            // A signed-out run waits a full minute for an OAuth code before
            // it fails; ask first, while the answer is still cheap.
            guard try await authenticationStatus() == .authenticated else {
                throw AnalysisError.authenticationRequired(
                    tool: tool,
                    loginCommand: tool.loginCommand(executableURL: executableURL)
                )
            }
            // agy lets the model call tools on its own unless a PreToolUse
            // hook denies them; the hook must leave `finish` alone, it is
            // what carries the structured output back.
            let hooksDirectory = temporaryDirectory.appendingPathComponent(
                ".agents", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: hooksDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try writePrivate(
                try Self.antigravityHooksData(),
                to: hooksDirectory.appendingPathComponent("hooks.json")
            )
            standardInput = try JSONSerialization.data(
                withJSONObject: [
                    "event": "user",
                    "message": ["role": "user", "content": promptText],
                ]
            ) + Data("\n".utf8)
        }
        let result: AnalysisCommandResult
        do {
            result = try await runner.run(
                AnalysisCommand(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput,
                    currentDirectoryURL: temporaryDirectory,
                    timeout: requestTimeout
                ),
                tool: tool
            )
        } catch {
            // A thrown run has no stdout, so the conversation id has to come
            // from agy's cache map instead; without it the run's files stay.
            #if os(macOS)
            if tool == .antigravity,
               let conversationID = AntigravityRunCleanup.conversationID(
                   forWorkingDirectory: temporaryDirectory
               ) {
                AntigravityRunCleanup.removeRun(conversationID: conversationID)
            }
            #endif
            throw error
        }
        // Claude reports API errors in stdout, sometimes even with exit code zero.
        // Inspect only error envelopes; never surface raw output containing meeting data.
        if tool == .claude,
           let failure = try? JSONDecoder().decode(ClaudeFailureEnvelope.self, from: result.standardOutput),
           failure.isError == true {
            if failure.apiErrorStatus == 401
                || failure.result?.localizedCaseInsensitiveContains("OAuth access token has expired") == true
                || failure.result?.hasPrefix("Failed to authenticate") == true {
                throw AnalysisError.authenticationRequired(
                    tool: tool,
                    loginCommand: tool.loginCommand(executableURL: executableURL)
                )
            }
            // A usage limit is the one error whose own text the user needs
            // ("You've hit your org's monthly spend limit"). Its first line
            // goes on only when it is short and reads as a limit; anything
            // else in the envelope stays out, as for every other error.
            var message = "Claude reported an API error" + (failure.apiErrorStatus.map { " (HTTP \($0))" } ?? "")
            if failure.apiErrorStatus == 429, let reason = Self.limitReason(failure.result) {
                message += ": " + reason
            } else {
                message += "."
            }
            throw AnalysisError.processFailed(tool: tool, exitCode: result.exitCode, message: message)
        }
        if tool == .antigravity {
            // stdout is NDJSON; only the last result event counts, the rest
            // of the lines carry other event kinds.
            let lines = String(decoding: result.standardOutput, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
            var runResult: AntigravityResult?
            for line in lines {
                guard let event = try? JSONDecoder().decode(
                    AntigravityStreamEvent.self,
                    from: Data(line.utf8)
                ), event.event == "result" else { continue }
                runResult = event.result
            }
            // The run leaves its conversation behind on disk whether it
            // succeeded or not.
            #if os(macOS)
            if let conversationID = runResult?.conversationID
                ?? AntigravityRunCleanup.conversationID(
                    forWorkingDirectory: temporaryDirectory
                ) {
                AntigravityRunCleanup.removeRun(conversationID: conversationID)
            }
            #endif
            guard let runResult, runResult.status == "SUCCESS", result.exitCode == 0 else {
                // Never the raw error or stdout: it may carry meeting content.
                let errorText = runResult?.error ?? ""
                if errorText.range(of: "authentication", options: .caseInsensitive) != nil {
                    throw AnalysisError.authenticationRequired(
                        tool: tool,
                        loginCommand: tool.loginCommand(executableURL: executableURL)
                    )
                }
                // A used-up quota reads like Claude's 429, so Dicavo shows
                // it as the tool's limit and not as a failed request.
                var message = Self.reportsAntigravityLimit(errorText)
                    ? "Antigravity reported an API error (HTTP 429)"
                    : "Antigravity reported an error"
                if let reason = Self.limitReason(errorText) {
                    message += ": " + reason
                }
                message += "."
                throw AnalysisError.processFailed(
                    tool: tool, exitCode: result.exitCode, message: message
                )
            }
            guard let structuredOutput = runResult.structuredOutput else {
                throw AnalysisError.invalidStructuredOutput(
                    "Antigravity returned no structured output."
                )
            }
            let responseData = try JSONEncoder().encode(structuredOutput)
            guard responseData.count <= AnalysisTransport.maximumMarkdownBytes + 100_000 else {
                throw AnalysisError.outputTooLarge
            }
            do {
                return try JSONDecoder().decode(AnalysisMarkdown.self, from: responseData).markdown
            } catch {
                throw AnalysisError.invalidStructuredOutput(error.localizedDescription)
            }
        }
        guard result.exitCode == 0 else {
            if tool == .codex,
               String(decoding: result.standardError, as: UTF8.self).contains("--ignore-user-config") {
                throw AnalysisError.processFailed(
                    tool: tool, exitCode: result.exitCode,
                    message: InterfaceLanguage.text("This version of Codex cannot run without the user's configuration. Update Codex and try again.")
                )
            }
            throw AnalysisError.processFailed(
                tool: tool,
                exitCode: result.exitCode,
                message: diagnostic(from: result.standardError)
            )
        }

        let responseData: Data
        switch tool {
        case .codex:
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                throw AnalysisError.invalidStructuredOutput(
                    "Codex did not create its structured response file."
                )
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: responseURL.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > AnalysisTransport.maximumMarkdownBytes + 100_000 {
                throw AnalysisError.outputTooLarge
            }
            responseData = try Data(contentsOf: responseURL)
        case .claude:
            responseData = try claudeStructuredOutput(from: result.standardOutput)
        case .antigravity, .appleIntelligence, .claudeAPI, .openAICompatibleAPI, .dicavoBridge, .localCommand, .unrecognized:
            throw AnalysisError.executableNotFound(path: tool.executableName)
        }
        guard responseData.count <= AnalysisTransport.maximumMarkdownBytes + 100_000 else {
            throw AnalysisError.outputTooLarge
        }

        do {
            return try JSONDecoder().decode(AnalysisMarkdown.self, from: responseData).markdown
        } catch {
            throw AnalysisError.invalidStructuredOutput(error.localizedDescription)
        }
    }

    /// The RE2 complement of "finish": matches every tool name except that
    /// one exactly. The hook denies them all; `finish` must stay allowed,
    /// it is the tool agy returns the structured output through.
    static let antigravityToolMatcher =
        #"^([^f].*|f([^i].*)?|fi([^n].*)?|fin([^i].*)?|fini([^s].*)?|finis([^h].*)?|finish.+)$"#

    /// A function, not a stored dictionary: the dictionary is not Sendable
    /// and a static stored constant would break strict concurrency.
    static func antigravityHooksData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "hooks": [
                    "PreToolUse": [
                        [
                            "matcher": antigravityToolMatcher,
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": #"cat >/dev/null; echo '{"decision":"deny","reason":"Dicavo analysis runs without tools."}'"#,
                                ]
                            ],
                        ]
                    ]
                ]
            ]
        )
    }

    func toolVersion() async throws -> String {
        try requireExecutable()
        let result = try await runner.run(
            AnalysisCommand(
                executableURL: executableURL,
                arguments: ["--version"],
                standardInput: Data(),
                currentDirectoryURL: executableURL.deletingLastPathComponent(),
                timeout: .seconds(15)
            ),
            tool: tool
        )
        guard result.exitCode == 0 else {
            throw AnalysisError.processFailed(
                tool: tool,
                exitCode: result.exitCode,
                message: diagnostic(from: result.standardError)
            )
        }
        let version = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? tool.displayName : version
    }

    func authenticationStatus() async throws -> AnalysisAuthenticationStatus {
        try requireExecutable()
        let result = try await runner.run(
            AnalysisCommand(
                executableURL: executableURL,
                arguments: tool.authenticationStatusArguments,
                standardInput: Data(),
                currentDirectoryURL: executableURL.deletingLastPathComponent(),
                timeout: .seconds(15)
            ),
            tool: tool
        )

        switch tool {
        case .codex:
            return result.exitCode == 0 ? .authenticated : .authenticationRequired
        case .antigravity:
            return result.exitCode == 0 ? .authenticated : .authenticationRequired
        case .claude:
            guard result.exitCode == 0 else {
                throw AnalysisError.processFailed(
                    tool: tool,
                    exitCode: result.exitCode,
                    message: diagnostic(from: result.standardError)
                )
            }
            let status = try? JSONDecoder().decode(
                ClaudeAuthenticationStatus.self,
                from: result.standardOutput
            )
            return status?.loggedIn == true ? .authenticated : .authenticationRequired
        case .appleIntelligence, .claudeAPI, .openAICompatibleAPI, .dicavoBridge, .localCommand, .unrecognized:
            throw AnalysisError.executableNotFound(path: tool.executableName)
        }
    }

    private func requireExecutable() throws {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw AnalysisError.executableNotFound(path: executableURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AnalysisError.executableNotRunnable(path: executableURL.path)
        }
    }

    /// Codex features a summary never needs, switched off for every run.
    /// The transcript is untrusted input, and each of these is a way for a
    /// sentence spoken in the meeting to reach the user's files, browser or
    /// accounts. Set through `-c`, which every Codex accepts and which
    /// ignores a name a given version does not have; `--disable` refuses one.
    static let codexDisabledFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "remote_plugin",
        "computer_use", "browser_use", "browser_use_external", "in_app_browser",
        "hooks", "multi_agent", "image_generation", "view_image", "skill_search",
        "skill_mcp_dependency_install", "tool_suggest", "goals",
    ]

    private func arguments(
        schemaData: Data,
        schemaURL: URL,
        responseURL: URL
    ) -> [String] {
        switch tool {
        case .codex:
            var values = [
                "exec",
                "--ephemeral",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                // The user's config.toml adds MCP servers and their own
                // settings; none of it belongs in a run fed with meeting
                // content. Authentication still comes from CODEX_HOME.
                "--ignore-user-config",
            ]
            for feature in Self.codexDisabledFeatures {
                values += ["-c", "features.\(feature)=false"]
            }
            values += [
                "-c", #"web_search="disabled""#,
                "--output-schema", schemaURL.path,
                "--output-last-message", responseURL.path,
                "--color", "never",
            ]
            if let model { values += ["--model", model] }
            values.append("-")
            return values
        case .claude:
            let schema = String(decoding: schemaData, as: UTF8.self)
            var values = [
                "--print",
                "--input-format", "text",
                "--output-format", "json",
                "--json-schema", schema,
                "--no-session-persistence",
                "--tools", "",
                "--permission-mode", "dontAsk",
                "--disable-slash-commands",
                "--strict-mcp-config",
                "--mcp-config", #"{"mcpServers":{}}"#,
                "--setting-sources", "",
            ]
            if let model { values += ["--model", model] }
            return values
        case .antigravity:
            // No `-p`: agy takes the prompt only over stream-json stdin.
            // The schema makes the final result carry structured_output.
            let schema = String(decoding: schemaData, as: UTF8.self)
            var values = [
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--json-schema", schema,
                "--disable-slash-commands",
            ]
            if let model { values += ["--model", model] }
            return values
        case .appleIntelligence, .claudeAPI, .openAICompatibleAPI, .dicavoBridge, .localCommand, .unrecognized:
            return []
        }
    }

    private func claudeStructuredOutput(from data: Data) throws -> Data {
        if (try? JSONDecoder().decode(AnalysisMarkdown.self, from: data)) != nil {
            return data
        }
        do {
            let envelope = try JSONDecoder().decode(ClaudeResultEnvelope.self, from: data)
            if let structured = envelope.structuredOutput {
                return try JSONEncoder().encode(structured)
            }
            if let result = envelope.result {
                return Data(result.utf8)
            }
            throw AnalysisError.invalidStructuredOutput(
                "Claude returned neither structured_output nor result."
            )
        } catch let error as AnalysisError {
            throw error
        } catch {
            throw AnalysisError.invalidStructuredOutput(error.localizedDescription)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Dicavo-AI-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func diagnostic(from data: Data) -> String {
        guard !data.isEmpty else { return "No diagnostic output. Check the AI tool in Settings, then retry AI analysis." }
        return "The command wrote \(data.count) bytes to stderr; its content was not persisted."
    }
}

private struct ClaudeResultEnvelope: Decodable {
    let result: String?
    let structuredOutput: AnalysisMarkdown?

    enum CodingKeys: String, CodingKey {
        case result
        case structuredOutput = "structured_output"
    }
}

/// One line of agy's NDJSON stdout; only `result` events carry the run's
/// outcome, every other event kind is ignored.
private struct AntigravityStreamEvent: Decodable {
    let event: String?
    let result: AntigravityResult?
}

private struct AntigravityResult: Decodable {
    let conversationID: String?
    let status: String?
    let error: String?
    let structuredOutput: AnalysisMarkdown?

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case status
        case error
        case structuredOutput = "structured_output"
    }
}

extension CLIAnalysisProvider {
    /// Whether an Antigravity error is a used-up quota or a rate limit. `agy`
    /// passes Google's `RESOURCE_EXHAUSTED` and HTTP 429 on; the exact text
    /// of a used-up free account was not seen yet, so the words are broad.
    static func reportsAntigravityLimit(_ errorText: String) -> Bool {
        errorText.range(
            of: #"RESOURCE_EXHAUSTED|\b429\b|quota|rate[ _-]?limit|usage limit"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// The first line of a 429 envelope when it is a short sentence about a
    /// limit, quota or credits; nil for anything else.
    static func limitReason(_ result: String?) -> String? {
        guard let line = result?.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespaces),
            !line.isEmpty, line.count <= 200,
            line.range(of: #"\b(limit|quota|credits?|usage)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        return line
    }
}

private struct ClaudeAuthenticationStatus: Decodable {
    let loggedIn: Bool
}


private struct ClaudeFailureEnvelope: Decodable {
    let isError: Bool?
    let apiErrorStatus: Int?
    let result: String?

    enum CodingKeys: String, CodingKey {
        case isError = "is_error"
        case apiErrorStatus = "api_error_status"
        case result
    }
}
