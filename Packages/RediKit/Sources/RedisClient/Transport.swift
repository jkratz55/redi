import Foundation

/// A bidirectional byte stream to a Redis server.
///
/// `write` must enqueue synchronously and preserve call order. `RedisConnection` relies on that to
/// keep replies matched to pipelined commands without an extra writer task.
public protocol RedisTransport: AnyObject, Sendable {
    /// Establishes the stream. Throws if it can't become ready within `timeout`.
    func start(timeout: Duration) async throws

    /// Enqueues bytes for sending. Failures surface through `read()` / connection closure.
    func write(_ bytes: [UInt8])

    /// Waits for the next chunk of bytes. Returns `nil` at end of stream.
    func read() async throws -> Data?

    /// Tears the stream down. Pending reads fail. Idempotent.
    func close()
}

/// Creates the transport for a configuration. Swappable so tests can inject in-memory transports.
public typealias RedisTransportFactory = @Sendable (RedisConnectionConfiguration) -> any RedisTransport
