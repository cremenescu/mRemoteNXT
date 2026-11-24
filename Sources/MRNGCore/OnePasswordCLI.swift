// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// Runs op, the 1Password command line tool. One read at a time, whoever asks, so that tabs
/// opened together do not start op in parallel and put up a prompt each.
public struct OnePasswordCLI {
    public let executable: URL
    /// A last resort. op gives up on an unanswered prompt by itself, after about two minutes.
    public var timeout: TimeInterval

    public init(executable: URL, timeout: TimeInterval = 180) {
        self.executable = executable
        self.timeout = timeout
    }

    // MARK: - Finding op

    /// Looks where Homebrew and the 1Password installer put op, then along PATH — which in an
    /// app started from the Finder is only the system's, so `path` can carry the shell's.
    public static func find(path: String? = ProcessInfo.processInfo.environment["PATH"],
                            fixed: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> URL? {
        let fromPath = (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for dir in fixed + fromPath {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("op")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// PATH as the user's shell has it. The shell is started as a terminal would start it,
    /// because PATH is as often set for interactive shells only, and may say something of its
    /// own on the way; the marks tell that apart from the answer.
    public static func shellPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                                 timeout: TimeInterval = 5) async -> String? {
        let mark = "@@path@@"
        let result = try? await OneShotProcess(executable: URL(fileURLWithPath: shell),
                                               arguments: ["-l", "-i", "-c", "printf '\(mark)%s\(mark)' \"$PATH\""])
            .run(timeout: timeout)
        guard let result, !result.timedOut else { return nil }
        let parts = String(decoding: result.stdout, as: UTF8.self).components(separatedBy: mark)
        return parts.count >= 3 ? parts[parts.count - 2] : nil
    }

    // MARK: - Commands

    /// Reads an item. Always from 1Password itself: op's own cache is turned off, so a
    /// password changed there is the one used at the next connect.
    public func item(_ reference: OnePasswordReference) async throws -> OnePasswordItem {
        try OnePasswordItem(json: try await run(Self.itemArguments(reference)))
    }

    /// The items of an account, for the picker.
    public func items(account: String = "") async throws -> [OnePasswordListedItem] {
        try OnePasswordListedItem.list(json: try await run(["item", "list"] + Self.options(account: account)))
    }

    public func accounts() async throws -> [OnePasswordAccount] {
        try OnePasswordAccount.list(json: try await run(["account", "list"] + Self.options()))
    }

    /// Needs no authorization and touches no account.
    public func version() async throws -> String {
        String(decoding: try await run(["--version"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The values come from a file that may have been written by anyone, so none of them may
    /// be taken for an option: flags are in the joined form and the item stands after "--".
    static func itemArguments(_ reference: OnePasswordReference) -> [String] {
        var args = ["item", "get"] + options(account: reference.account)
        if !reference.vault.isEmpty { args.append("--vault=" + reference.vault) }
        return args + ["--", reference.item]
    }

    private static func options(account: String = "") -> [String] {
        var args = ["--format=json", "--cache=false", "--no-color"]
        if !account.isEmpty { args.append("--account=" + account) }
        return args
    }

    // MARK: - Running

    private static let gate = SerialGate()

    /// Runs op and returns what it printed. Cancelling the task stops op, whether it was
    /// waiting for its turn or for an answer to the prompt.
    public func run(_ arguments: [String]) async throws -> Data {
        try await Self.gate.enter()
        do {
            try Task.checkCancellation()
            let result = try await OneShotProcess(executable: executable, arguments: arguments).run(timeout: timeout)
            let error: OnePasswordError? = if result.timedOut {
                .timedOut
            } else if result.status != 0 {
                .classify(String(decoding: result.stderr, as: UTF8.self))
            } else {
                nil
            }
            // Whoever waits in line would put up the same prompt again: a dozen tabs reopened
            // at launch would take a dozen refusals. They all get this answer instead.
            switch error {
            case .declined, .timedOut: await Self.gate.leave(failing: error)
            default: await Self.gate.leave()
            }
            if let error { throw error }
            return result.stdout
        } catch is LaunchFailure {
            await Self.gate.leave()
            throw OnePasswordError.notInstalled
        } catch let error as OnePasswordError {
            throw error
        } catch {
            await Self.gate.leave()
            throw error
        }
    }
}

private struct LaunchFailure: Error {}

/// Lets one caller through at a time, in the order they came.
actor SerialGate {
    private var busy = false
    private var waiting: [(id: UUID, resume: CheckedContinuation<Void, Error>)] = []

    func enter() async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                // Cancelled before getting here: the handler has already run and found nothing.
                if Task.isCancelled { c.resume(throwing: CancellationError()) } else { waiting.append((id, c)) }
            }
        } onCancel: {
            Task { await self.giveUp(id) }
        }
    }

    /// `failing` turns away everyone waiting, with that error.
    func leave(failing error: Error? = nil) {
        if let error {
            let turnedAway = waiting
            waiting = []
            turnedAway.forEach { $0.resume.resume(throwing: error) }
        }
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume.resume() }
    }

    private func giveUp(_ id: UUID) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).resume.resume(throwing: CancellationError())
    }
}

/// A process run once to its end, both pipes drained as it goes (reading one to the end
/// first hangs a tool that fills the other one meanwhile).
private final class OneShotProcess: @unchecked Sendable {
    struct Result { var status: Int32; var stdout: Data; var stderr: Data; var timedOut: Bool }

    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var timedOut = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        // op takes item names from standard input when there is one.
        process.standardInput = FileHandle.nullDevice
    }

    func run(timeout: TimeInterval) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { c.resume(returning: try self.runBlocking(timeout: timeout)) } catch { c.resume(throwing: error) }
                }
            }
        } onCancel: {
            self.stop(markCancelled: true)
        }
    }

    private func runBlocking(timeout: TimeInterval) throws -> Result {
        let out = PipeReader(), err = PipeReader()
        let exited = DispatchSemaphore(value: 0)
        process.standardOutput = out.pipe
        process.standardError = err.pipe
        process.terminationHandler = { _ in exited.signal() }

        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw LaunchFailure() }
        started = true
        lock.unlock()
        out.start()
        err.start()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); timedOut = true; lock.unlock()
            stop(markCancelled: false)
            exited.wait()
        }
        // The answer is complete once op is gone. Something it left running may still hold
        // the pipes open, and must not keep the answer waiting.
        let stdout = out.finish(), stderr = err.finish()

        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        return Result(status: process.terminationReason == .exit ? process.terminationStatus : -1,
                      stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    private func stop(markCancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if markCancelled { cancelled = true }
        guard started, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private final class PipeReader: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private let ended = DispatchSemaphore(value: 0)
    private var data = Data()

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended.signal()
            } else {
                lock.lock(); data.append(chunk); lock.unlock()
            }
        }
    }

    func finish() -> Data {
        if ended.wait(timeout: .now() + 1) == .timedOut {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
