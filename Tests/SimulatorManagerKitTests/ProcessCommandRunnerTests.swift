import Foundation
import Testing
@testable import SimulatorManagerKit

/// Guards the process plumbing itself, using a stand-in executable rather than
/// `xcrun`, so these run on any machine with or without Xcode.
///
/// These exist because of a real defect: an earlier version resumed its
/// continuation from `Process.terminationHandler` while the pipe reads were still
/// in flight. The 6 KB device listing survived that; the 20 KB runtime listing did
/// not, and failed only against a real machine. Output size is the trigger, so
/// these tests pin the behaviour at sizes well past the 64 KB pipe buffer.
@Suite("Process command execution")
struct ProcessCommandRunnerTests {

    private func makeScript(_ body: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simpilot-fake-xcrun-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("Output far larger than the pipe buffer arrives intact")
    func doesNotTruncateLargeOutput() async throws {
        // 512 KB, eight times the 64 KB pipe buffer.
        let script = try makeScript("""
        i=0
        while [ $i -lt 8192 ]; do
          printf '%064d\\n' $i
          i=$((i+1))
        done
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let result = try await ProcessCommandRunner(xcrunURL: script).run(.listRuntimes)

        #expect(result.isSuccess)
        #expect(result.standardOutput.count == 8192 * 65)
        let text = try #require(String(data: result.standardOutput, encoding: .utf8))
        #expect(text.hasSuffix(String(format: "%064d\n", 8191)), "output was truncated")
    }

    /// Filling one pipe while the reader waits on the other is the deadlock this
    /// runner must avoid; both are drained concurrently.
    @Test("Large output on both pipes at once does not deadlock")
    func drainsBothPipesConcurrently() async throws {
        let script = try makeScript("""
        i=0
        while [ $i -lt 4096 ]; do
          printf '%064d\\n' $i
          printf '%064d\\n' $i >&2
          i=$((i+1))
        done
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let result = try await ProcessCommandRunner(xcrunURL: script).run(.listDevices)

        #expect(result.standardOutput.count == 4096 * 65)
        #expect(result.standardError.count == 4096 * 65)
    }

    @Test("A non-zero exit is reported with its stderr")
    func reportsFailureExitCode() async throws {
        let script = try makeScript("echo 'Invalid device' >&2\nexit 164")
        defer { try? FileManager.default.removeItem(at: script) }

        let result = try await ProcessCommandRunner(xcrunURL: script).run(.listDevices)

        #expect(result.isSuccess == false)
        #expect(result.exitCode == 164)
        #expect(result.standardErrorText == "Invalid device")
    }

    @Test("A missing executable is reported as a missing toolchain")
    func reportsMissingExecutable() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/xcrun-\(UUID().uuidString)")
        let runner = ProcessCommandRunner(xcrunURL: missing)

        await #expect(throws: SimctlError.self) {
            _ = try await runner.run(.listDevices)
        }
    }

    @Test("Arguments reach the executable in order")
    func passesArgumentsThrough() async throws {
        let script = try makeScript("echo \"$@\"")
        defer { try? FileManager.default.removeItem(at: script) }

        let id = try #require(UUID(uuidString: "32D5B2B1-B8FF-4846-840D-E49B15F4141F"))
        let result = try await ProcessCommandRunner(xcrunURL: script).run(.deleteDevice(id: id))

        let text = String(data: result.standardOutput, encoding: .utf8) ?? ""
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines)
                == "simctl delete 32D5B2B1-B8FF-4846-840D-E49B15F4141F")
    }

    @Test("Concurrent commands do not interfere")
    func handlesConcurrentInvocations() async throws {
        // Arguments are `simctl delete <UUID>`, so the UUID is the third.
        let script = try makeScript("printf '%s' \"$3\"")
        defer { try? FileManager.default.removeItem(at: script) }

        let runner = ProcessCommandRunner(xcrunURL: script)
        let ids = (0..<12).map { _ in UUID() }

        let results = try await withThrowingTaskGroup(of: (UUID, String).self) { group in
            for id in ids {
                group.addTask {
                    let result = try await runner.run(.deleteDevice(id: id))
                    return (id, String(data: result.standardOutput, encoding: .utf8) ?? "")
                }
            }
            var collected: [UUID: String] = [:]
            for try await (id, output) in group { collected[id] = output }
            return collected
        }

        #expect(results.count == 12)
        for id in ids {
            #expect(results[id] == id.uuidString, "a concurrent run received another's output")
        }
    }
}
