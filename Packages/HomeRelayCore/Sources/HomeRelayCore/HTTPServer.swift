import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

public struct HTTPRequest: Sendable {
    public var method: String
    /// Percent-decoded path segments, e.g. `["api", "v1", "accessories", "Desk Lamp"]`.
    public var segments: [String]
    public var query: [String: String]
    /// Lowercased header names.
    public var headers: [String: String]
    public var body: Data
    public var remoteAddress: String?

    public init(method: String, segments: [String], query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data(), remoteAddress: String? = nil) {
        self.method = method
        self.segments = segments
        self.query = query
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    public var path: String { "/" + segments.joined(separator: "/") }

    /// Parses an HTTP request target such as `/api/v1/accessories/Desk%20Lamp?refresh=1`.
    public static func parseTarget(_ uri: String) -> (segments: [String], query: [String: String]) {
        let parts = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let segments = (parts.first ?? "")
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        return (segments, query)
    }
}

public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        /// Written chunk by chunk until the stream finishes or the client leaves.
        case stream(AsyncStream<Data>)
    }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Body

    public init(status: Int, headers: [(String, String)] = [], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// A small HTTP/1.1 server. Each connection handles requests in order with
/// keep-alive; streamed responses (server-sent events) end the connection.
public final class HTTPServer: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let host: String
    private let port: Int
    private let maxBodyBytes: Int
    private let idleTimeout: TimeAmount
    private let handler: Handler

    /// `idleTimeout` closes connections with no traffic either way, so clients
    /// that vanish (an ESP32 losing Wi-Fi) don't hold sockets forever. Event
    /// streams stay open because their keepalives count as traffic.
    public init(host: String, port: Int, maxBodyBytes: Int = 64 * 1024, idleTimeout: TimeAmount = .seconds(120), handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.maxBodyBytes = maxBodyBytes
        self.idleTimeout = idleTimeout
        self.handler = handler
    }

    /// Binds and serves until the surrounding task is cancelled. `onBound`
    /// receives the actual port, which matters when `port` is 0.
    public func run(onBound: @Sendable (Int) -> Void = { _ in }) async throws {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { [idleTimeout] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IdleStateHandler(allTimeout: idleTimeout))
                    try channel.pipeline.syncOperations.addHandler(CloseWhenIdle())
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: channel)
                }
            }
        onBound(server.channel.localAddress?.port ?? port)

        try await withThrowingDiscardingTaskGroup { group in
            try await server.executeThenClose { connections in
                for try await connection in connections {
                    group.addTask { await self.serve(connection) }
                }
            }
        }
    }

    private func serve(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async {
        let remote = connection.channel.remoteAddress?.ipAddress
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                var body = ByteBuffer()
                var tooLarge = false

                for try await part in inbound {
                    switch part {
                    case .head(let h):
                        head = h
                        body.clear()
                        tooLarge = false
                    case .body(var chunk):
                        if body.readableBytes + chunk.readableBytes > maxBodyBytes {
                            tooLarge = true
                        } else {
                            body.writeBuffer(&chunk)
                        }
                    case .end:
                        guard let h = head else { continue }
                        head = nil
                        let response: HTTPResponse
                        if tooLarge {
                            response = APIRouter.errorResponse(APIError(status: 413, code: "too_large", message: "Request body is over \(maxBodyBytes) bytes"))
                        } else {
                            var headers: [String: String] = [:]
                            for (name, value) in h.headers { headers[name.lowercased()] = value }
                            let target = HTTPRequest.parseTarget(h.uri)
                            let request = HTTPRequest(
                                method: h.method.rawValue,
                                segments: target.segments,
                                query: target.query,
                                headers: headers,
                                body: Data(body.readableBytesView),
                                remoteAddress: remote
                            )
                            response = await handler(request)
                        }
                        let keepAlive = try await write(response, version: h.version, keepAlive: h.isKeepAlive, to: outbound)
                        if !keepAlive { return }
                    }
                }
            }
        } catch {
            // Client went away mid-request; nothing to report.
        }
    }

    /// Returns whether the connection can take another request.
    private func write(
        _ response: HTTPResponse, version: HTTPVersion, keepAlive: Bool,
        to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws -> Bool {
        var headers = HTTPHeaders(response.headers)
        let status = HTTPResponseStatus(statusCode: response.status)
        switch response.body {
        case .data(let data):
            headers.replaceOrAdd(name: "Content-Length", value: String(data.count))
            headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
            try await outbound.write(.head(HTTPResponseHead(version: version, status: status, headers: headers)))
            if !data.isEmpty {
                try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: data))))
            }
            try await outbound.write(.end(nil))
            return keepAlive
        case .stream(let stream):
            headers.replaceOrAdd(name: "Connection", value: "close")
            try await outbound.write(.head(HTTPResponseHead(version: version, status: status, headers: headers)))
            for await chunk in stream {
                try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: chunk))))
            }
            try await outbound.write(.end(nil))
            return false
        }
    }
}

/// Closes the connection when `IdleStateHandler` reports no traffic.
private final class CloseWhenIdle: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}
