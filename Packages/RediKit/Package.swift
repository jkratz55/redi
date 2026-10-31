// swift-tools-version: 6.2
import PackageDescription

// RediKit holds everything in Redi that isn't UI. Code here is nonisolated by default (unlike the
// app target, which defaults to MainActor), so protocol parsing, scanning and aggregation never
// land on the main thread by accident.
//
// Layering (each target only depends on the ones above it):
//   RedisWire    – RESP2/RESP3 values, incremental parser, encoder. No dependencies.
//   RedisClient  – transports, connections, handshake, TLS, (later) cluster & sentinel.
//   RediCore     – sessions and domain services used by the app.
let package = Package(
    name: "RediKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RediKit", targets: ["RedisWire", "RedisClient", "RediCore"]),
        .executable(name: "redi-seed", targets: ["RediSeed"]),
        .executable(name: "redi-tools", targets: ["RediTools"]),
    ],
    targets: [
        .target(name: "RedisWire"),
        .target(name: "RedisClient", dependencies: ["RedisWire"]),
        .target(name: "RediCore", dependencies: ["RedisWire", "RedisClient"], resources: [.copy("Resources/commands.json")]),

        // Test-only helpers: an in-memory scripted transport and a local redis-server fixture.
        .target(name: "RedisTestSupport", dependencies: ["RedisWire", "RedisClient"]),

        // Dataset generator: writes RESP commands to stdout for `redis-cli --pipe`.
        .executableTarget(name: "RediSeed", dependencies: ["RedisWire"]),

        // Maintenance: regenerates the bundled command catalog.
        .executableTarget(name: "RediTools", dependencies: ["RedisWire", "RedisClient", "RediCore"]),

        .testTarget(name: "RedisWireTests", dependencies: ["RedisWire"]),
        .testTarget(name: "RedisClientTests", dependencies: ["RedisClient", "RedisTestSupport"]),
        .testTarget(name: "RediCoreTests", dependencies: ["RediCore", "RedisTestSupport"]),
    ]
)
