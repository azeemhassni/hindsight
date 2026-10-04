import Foundation
import HindsightCore
import Testing
@testable import HindsightProcess

@Suite("Process concurrency", .timeLimit(.minutes(1)))
struct ProcessConcurrencyTests {
    /// A background agent runs many processes at once. An implementation that
    /// parks a thread per stream deadlocks here once the pool is exhausted.
    @Test("runs many processes at once without starving or deadlocking")
    func runsManyProcessesConcurrently() async throws {
        let runner = ProcessRunner()
        let count = 60

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await runner.run(
                        Command(path: "/bin/echo", arguments: ["job-\(index)"])
                    ).standardOutput
                }
            }
            var collected: [String] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        #expect(results.count == count)
        #expect(Set(results).count == count)
    }

    @Test("delivers standard input reliably under concurrency")
    func deliversStandardInputConcurrently() async throws {
        let runner = ProcessRunner()
        let count = 60

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await runner.run(
                        Command(
                            path: "/bin/cat",
                            standardInput: .data(Data("payload-\(index)\n".utf8))
                        )
                    ).standardOutput
                }
            }
            var collected: [String] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        #expect(Set(results).count == count)
        #expect(results.allSatisfy { $0.hasPrefix("payload-") })
    }
}
