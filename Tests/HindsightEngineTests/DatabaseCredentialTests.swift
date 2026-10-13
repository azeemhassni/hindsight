import Foundation
import HindsightCore
import Testing
@testable import HindsightEngine

/// The Redis dump failed on brahui.dev for ten minutes per instance and then
/// filed an empty snapshot as a backup. These cover each thing that was wrong,
/// against the `docker inspect` output and `redis-cli` behaviour reproduced in
/// a local container.
@Suite("Database credentials")
struct DatabaseCredentialTests {
    /// As `docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}'`
    /// prints it for a Coolify-style Redis, with the command after the marker.
    private let redisInspect = [
        "PATH=/usr/local/sbin:/usr/local/bin",
        "REDIS_VERSION=7.4.1",
        "REDIS_DOWNLOAD_URL=https://download.redis.io/releases/redis-7.4.1.tar.gz",
        "REDIS_PASSWORD=hunter2",
        "---hindsight-cmd---",
        "redis-server",
        "--requirepass",
        "fromarguments",
    ]

    @Test("finds a Redis password in the container's environment")
    func findsRedisPassword() {
        #expect(
            DatabaseCredentialDiscovery.password(inEnvironment: redisInspect, engine: .redis)
                == "hunter2"
        )
    }

    /// `REDIS_DOWNLOAD_URL` and friends contain the word Redis and must not be
    /// mistaken for a credential.
    @Test("does not mistake another Redis variable for the password")
    func ignoresOtherVariables() {
        let withoutPassword = redisInspect.filter { !$0.hasPrefix("REDIS_PASSWORD=") }
        #expect(
            DatabaseCredentialDiscovery.password(inEnvironment: withoutPassword, engine: .redis)
                == nil
        )
    }

    @Test("falls back to --requirepass on the command line")
    func readsRequirepass() {
        let withoutPassword = redisInspect.filter { !$0.hasPrefix("REDIS_PASSWORD=") }
        #expect(
            DatabaseCredentialDiscovery.password(inArguments: withoutPassword) == "fromarguments"
        )
        #expect(
            DatabaseCredentialDiscovery.password(
                inArguments: ["---hindsight-cmd---", "redis-server", "--requirepass=inline"]
            ) == "inline"
        )
        // A flag with nothing after it is not a password.
        #expect(
            DatabaseCredentialDiscovery.password(
                inArguments: ["---hindsight-cmd---", "redis-server", "--requirepass", "--appendonly"]
            ) == nil
        )
    }

    @Test("reads each engine's own variable")
    func engineVariables() {
        let cases: [(DatabaseEngine, String)] = [
            (.postgres, "POSTGRES_PASSWORD=pg"),
            (.mysql, "MYSQL_ROOT_PASSWORD=my"),
            (.mariadb, "MARIADB_ROOT_PASSWORD=maria"),
            (.mongodb, "MONGO_INITDB_ROOT_PASSWORD=mongo"),
        ]
        for (engine, line) in cases {
            let value = DatabaseCredentialDiscovery.password(inEnvironment: [line], engine: engine)
            #expect(value == line.split(separator: "=").last.map(String.init))
        }
    }

    @Test("an environment variable set to nothing is not a password")
    func ignoresEmptyValues() {
        #expect(
            DatabaseCredentialDiscovery.password(inEnvironment: ["REDIS_PASSWORD="], engine: .redis)
                == nil
        )
    }

    /// Reproduced in a container: `redis-cli` answers `(error) NOAUTH
    /// Authentication required.` on *stdout* and exits zero, so `tr -dc '0-9'`
    /// left an empty string. The old script compared that with the previous
    /// empty string, never saw a difference, and slept through 600 attempts.
    @Test("the Redis dump refuses to poll when it cannot read LASTSAVE")
    func redisFailsFastWithoutAuth() throws {
        let target = DatabaseTarget(
            engine: .redis,
            location: .container(name: "cache", image: "redis:7")
        )
        let script = try DatabaseDumpCommand.engineCommand(for: target)

        // Fails on an empty LASTSAVE instead of entering the loop.
        #expect(script.contains("if [ -z \"$previous\" ]"))
        #expect(script.contains("exit 74"))
        // And the wait is no longer ten minutes.
        #expect(script.contains("seq 1 120"))
        #expect(!script.contains("seq 1 600"))
    }

    /// `--no-raw` keeps the `2) ` prefix that `CONFIG GET` numbers its values
    /// with, so the path came out as `2) /data/2) dump.rdb` and the read would
    /// have failed even with a password. Verified against redis 7 in Docker.
    @Test("the Redis dump reads the RDB path without the list prefix")
    func redisReadsRawConfig() throws {
        let target = DatabaseTarget(
            engine: .redis,
            location: .container(name: "cache", image: "redis:7")
        )
        let script = try DatabaseDumpCommand.engineCommand(for: target)

        #expect(script.contains("redis-cli CONFIG GET dir"))
        #expect(!script.contains("--no-raw"))
        // And it checks the file is really there before streaming it.
        #expect(script.contains("! -s \"$directory/$filename\""))
    }

    /// `docker exec` begins with the container's environment, so a password
    /// set for the ssh command never reached `redis-cli`. Verified against
    /// redis 7 in Docker: `-e NAME` forwards the caller's value, while
    /// `-e NAME=value` would put the password in `argv`.
    @Test("forwards the password into the container without putting it in argv")
    func forwardsPasswordIntoContainer() throws {
        let redis = DatabaseTarget(
            engine: .redis,
            location: .container(name: "cache", image: "redis:7")
        )
        let pipeline = try DatabaseDumpCommand.pipeline(for: redis)
        #expect(pipeline.contains("-e REDISCLI_AUTH "))
        // The pass-through form. `-e NAME=` would carry the value itself, and
        // `docker exec`'s arguments are as readable as any other `argv`.
        #expect(!pipeline.contains("-e REDISCLI_AUTH="))

        // And the script falls back to the password the container already
        // carries, which is where Redis itself read it from.
        let script = try DatabaseDumpCommand.engineCommand(for: redis)
        #expect(script.contains("REDIS_PASSWORD"))
        // An empty value is unset rather than exported: `REDISCLI_AUTH=""`
        // makes redis-cli attempt an authentication and fail WRONGPASS.
        #expect(script.contains("unset REDISCLI_AUTH"))
    }
}

/// Runs the generated pipeline against a real password-protected Redis.
///
/// `HINDSIGHT_REDIS_CONTAINER` names a local container; nothing else is
/// touched. This is the check that the whole chain works rather than its parts
/// separately — every one of the four bugs here passed the unit tests that
/// existed. Start one with:
///
///     docker run -d --rm --name hs-redis -e REDIS_PASSWORD=s3cret \
///       redis:7-alpine redis-server --requirepass s3cret
@Suite("Redis dump against a container")
struct RedisDumpContainerTests {
    @Test(
        "dumps a password-protected Redis end to end",
        .enabled(if: ProcessInfo.processInfo.environment["HINDSIGHT_REDIS_CONTAINER"] != nil)
    )
    func dumpsPasswordProtectedRedis() throws {
        let name = ProcessInfo.processInfo.environment["HINDSIGHT_REDIS_CONTAINER"]!
        let target = DatabaseTarget(engine: .redis, location: .container(name: name, image: "redis:7"))
        let pipeline = try DatabaseDumpCommand.pipeline(for: target)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", pipeline]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        print("REDISTEST status=\(process.terminationStatus) bytes=\(data.count)")
        if !stderr.isEmpty { print("REDISTEST stderr: \(stderr)") }
        #expect(process.terminationStatus == 0)
        // An RDB file, not an error message: the magic is the proof.
        #expect(data.count > 0)
        #expect(data.prefix(5) == Data("REDIS".utf8))
    }
}
