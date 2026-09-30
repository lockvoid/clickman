import Foundation
import os
@testable import ClickMan

/// Answers every request of a stubbed URLSession with a scripted status, after
/// a scripted delay, and records what was sent and how many were in flight at
/// once. Status 0 is no answer at all: the connection fails.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private struct State {
        var status = 202
        var retryAfter: String?
        var delay: TimeInterval = 0
        var requests: [Request] = []
        var inFlight = 0
        var mostInFlight = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Forgets what was sent; every request from now on is answered with `status` after `delay`.
    static func reset(status: Int = 202, retryAfter: String? = nil, delay: TimeInterval = 0) {
        state.withLock { $0 = State(status: status, retryAfter: retryAfter, delay: delay) }
    }

    /// Answers later requests with `status`, keeping what was sent.
    static func answer(_ status: Int, retryAfter: String? = nil) {
        state.withLock { state in
            state.status = status
            state.retryAfter = retryAfter
        }
    }

    static var requests: [Request] {
        state.withLock { $0.requests }
    }

    static var mostInFlight: Int {
        state.withLock { $0.mostInFlight }
    }

    /// Every batch received, as JSON.
    static func batches() throws -> [JSONValue] {
        try requests.map { try JSONValue(JSONSerialization.jsonObject(with: gunzip($0.body))) }
    }

    /// Every event received, in the order sent.
    static func events() throws -> [JSONValue] {
        try batches().flatMap { batch in
            guard case .array(let events)? = batch["batch"] else {
                throw JSONValue.NotJSON(description: "a batch without events: \(batch)")
            }
            return events
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (status, retryAfter, delay) = Self.record(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            Self.state.withLock { $0.inFlight -= 1 }
            self.respond(status: status, retryAfter: retryAfter)
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, retryAfter: String?) {
        guard status != 0 else {
            return client!.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
        var headers = ["Content-Type": "application/json"]
        headers["Retry-After"] = retryAfter
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Data(#"{"accepted":1,"duplicates":0,"rejected":[]}"#.utf8))
        client!.urlProtocolDidFinishLoading(self)
    }

    private static func record(_ request: URLRequest) -> (status: Int, retryAfter: String?, delay: TimeInterval) {
        let body = request.httpBody ?? request.httpBodyStream.map(read) ?? Data()
        let recorded = Request(method: request.httpMethod!, url: request.url!, headers: request.allHTTPHeaderFields!, body: body)
        return state.withLock { state in
            state.requests.append(recorded)
            state.inFlight += 1
            state.mostInFlight = max(state.mostInFlight, state.inFlight)
            return (state.status, state.retryAfter, state.delay)
        }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Undoes gzip: a 10-byte header, a raw deflate stream, an 8-byte trailer.
func gunzip(_ data: Data) throws -> Data {
    try (data.subdata(in: 10..<(data.count - 8)) as NSData).decompressed(using: .zlib) as Data
}
