// The proof vehicle (ADR-0013, Decision 2): a real HTTP server on a real loopback socket, stood
// up inside the test process.
//
// WHY SOCKETS AND NOT `URLProtocol`. URLProtocol interception is hermetic and faster, and it can
// prove decoding and error mapping. It CANNOT prove the timeout: it replaces URLSession's loading
// system, so `timeoutIntervalForRequest` is never consulted and the test would hand back the very
// error it claims to have observed. That is a fabricated proof of the one path this rung adds —
// the same defect ADR-0010 refused when it banned a canned success. It also cannot exercise the
// connection lifecycle, which is what ADR-0013's cold rule rests on.
//
// WHAT THIS DOES NOT READ, stated because every check in this repo owes that sentence
// (docs/ROADMAP.md, "every new check states what it does NOT read"):
//   - It is not an inference server. `/classify` answers a FIXED, obviously-synthetic response and
//     never looks at the tensor's contents. It proves the wire contract and the engine's handling
//     of it; it proves nothing about any real remote model's accuracy, and no number it returns is
//     quoted anywhere as a measurement.
//   - It parses only as much HTTP as these tests send: one request per connection, `Content-Length`
//     framing, no chunked encoding, no keep-alive pipelining, no TLS. A general HTTP server would
//     be a product; this is a fixture.
//   - It runs on loopback in the same process, so it says nothing about latency, real networks,
//     proxies, or captive portals.
//
// Concurrency: `NetworkListener` is `Sendable` under Swift 6 and its `run` handler is an async
// closure, so the whole fixture is actor-isolated with no `@unchecked Sendable` anywhere — the
// older `NWListener`/`NWConnection` pair is not Sendable and would have needed one, which
// invariant 2 reserves for the LiteRT C boundary alone.

import Foundation
import Network

/// A loopback HTTP server with exactly four routes, one per path under test.
///
/// | Route | Behaviour | What it proves |
/// |---|---|---|
/// | `/classify` | reads the body, answers the contract's JSON | round trip, decode, label mapping, the wire contract |
/// | `/slow` | accepts, reads, never responds | a REAL timeout through URLSession's own config |
/// | `/boom` | `500` with a body | server-error handling |
/// | `/liar` | well-formed JSON with `confidence: 1.7` | the engine VALIDATES an untrusted response instead of clamping it |
///
/// One server per test: startup is cheap, and a shared instance would let `/slow`'s held-open
/// connection become a reason some other test flaked.
actor LoopbackServer {
    /// What the last `/classify` request actually carried. The wire contract is only proven if
    /// something checks what crossed, not just what came back.
    struct RecordedRequest: Sendable {
        let path: String
        let contentType: String?
        let inputDescription: String?
        let bodyByteCount: Int
    }

    private var listener: NetworkListener<TCP>?
    private var task: Task<Void, Never>?
    private var recorded: RecordedRequest?

    /// The JSON `/classify` answers. Synthetic and flagged as such: index 653 is `"military
    /// uniform"` in the derived table, which is what makes the label-mapping assertion checkable.
    static let cannedTop: [(index: Int, confidence: Float)] = [
        (653, 0.81), (518, 0.07), (400, 0.02),
    ]

    /// Bind an ephemeral loopback port and start serving. Returns the port the kernel assigned.
    func start() async throws -> UInt16 {
        var parameters = NWParameters.tcp
        // Loopback only. A test fixture that binds every interface is a test fixture listening on
        // the network, which is not what anyone consented to by running the suite.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener = try NetworkListener(
            using: NWParametersBuilder.parameters(initialParameters: parameters) { TCP() }
        )
        self.listener = listener

        // `run` does not return until the listener is torn down, so it owns its own task and the
        // caller waits below for the port to appear.
        task = Task {
            try? await listener.run { connection in
                try? await Self.serve(connection, into: self)
            }
        }

        // Poll for the assigned port rather than bridging a state callback into a continuation:
        // the callback can fire before the continuation is installed, and a fixture that
        // deadlocks on a race is worse than one that spins for a few milliseconds.
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ServerError.didNotBind
    }

    func stop() {
        task?.cancel()
        task = nil
        listener = nil
    }

    func lastRequest() -> RecordedRequest? { recorded }

    private func record(_ request: RecordedRequest) {
        recorded = request
    }

    enum ServerError: Error {
        case didNotBind
        case malformedRequest
    }

    // MARK: - One connection, one request

    private static func serve(
        _ connection: NetworkConnection<TCP>, into server: LoopbackServer
    ) async throws {
        var buffer = Data()

        // Read until the header terminator. `atMost` is generous; `atLeast: 1` means this returns
        // as soon as anything arrives, so the loop is driven by the terminator, not by a size.
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            let message = try await connection.receive(atLeast: 1, atMost: 64 * 1024)
            buffer.append(contentsOf: message.content)
            if message.content.isEmpty { throw ServerError.malformedRequest }
        }

        guard let headerEnd = buffer.range(of: terminator),
              let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8)
        else { throw ServerError.malformedRequest }

        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { throw ServerError.malformedRequest }
        let path = String(requestLine.split(separator: " ").dropFirst().first ?? "/")

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Drain the body so the client's write completes before any response is written. Without
        // this, a large POST answered early can surface to the client as a broken pipe rather than
        // as the response under test.
        let declared = Int(headers["content-length"] ?? "0") ?? 0
        var body = buffer[headerEnd.upperBound...].count
        while body < declared {
            let message = try await connection.receive(
                atLeast: 1, atMost: min(64 * 1024, declared - body)
            )
            if message.content.isEmpty { break }
            body += message.content.count
        }

        await server.record(RecordedRequest(
            path: path,
            contentType: headers["content-type"],
            inputDescription: headers["x-inferlens-input"],
            bodyByteCount: body
        ))

        switch path {
        case "/slow":
            // Accepted, read in full, and deliberately never answered. The client's own
            // `timeoutIntervalForRequest` is what ends this — which is the entire point of using a
            // real socket, and exactly what URLProtocol could not have produced.
            try await Task.sleep(for: .seconds(600))

        case "/boom":
            try await respond(connection, status: "500 Internal Server Error", json: #"{"error":"boom"}"#)

        case "/liar":
            // Well-formed JSON, a valid status, and a confidence the contract forbids. The engine
            // must refuse it: a probability above 1 is not repairable into a fact.
            try await respond(
                connection,
                status: "200 OK",
                json: #"{"model":"loopback-fixture","top":[{"index":653,"confidence":1.7}]}"#
            )

        default:
            let entries = cannedTop
                .map { #"{"index":\#($0.index),"confidence":\#($0.confidence)}"# }
                .joined(separator: ",")
            try await respond(
                connection,
                status: "200 OK",
                json: #"{"model":"loopback-fixture","top":[\#(entries)]}"#
            )
        }
    }

    private static func respond(
        _ connection: NetworkConnection<TCP>, status: String, json: String
    ) async throws {
        let body = Data(json.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        try await connection.send(Data(head.utf8) + body, endOfStream: true)
    }
}
