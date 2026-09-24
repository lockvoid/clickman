import Foundation
import os

/// Answers every request of a stubbed URLSession with a scripted status and
/// records what was sent.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private static let state = OSAllocatedUnfairLock(initialState: (status: 202, retryAfter: String?.none, requests: [Request]()))

    static func reset(status: Int = 202, retryAfter: String? = nil) {
        state.withLock { $0 = (status, retryAfter, []) }
    }

    static var requests: [Request] {
        state.withLock { $0.requests }
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
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let recorded = Request(url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let (status, retryAfter) = Self.state.withLock { state in
            state.requests.append(recorded)
            return (state.status, state.retryAfter)
        }

        var headers = ["Content-Type": "application/json"]
        headers["Retry-After"] = retryAfter
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"accepted":1,"duplicates":0,"rejected":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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
