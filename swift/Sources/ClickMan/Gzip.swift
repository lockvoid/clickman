import Foundation
import zlib

/// A batch as one gzip member (RFC 1952), the body `Content-Encoding: gzip` promises.
enum Gzip {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func compress(_ data: Data) throws -> Data {
        guard data.count <= Int(uInt.max) else {
            throw Failure(description: "gzip input exceeds its size limit")
        }

        var stream = z_stream()
        let initialized = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8,
                                        Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else {
            throw Failure(description: "gzip compression initialization failed: \(initialized)")
        }
        defer { deflateEnd(&stream) }

        return try deflateWhole(data, into: &stream)
    }

    private static func deflateWhole(_ data: Data, into stream: inout z_stream) throws -> Data {
        let capacity = deflateBound(&stream, uLong(data.count))
        guard capacity <= uInt.max else {
            throw Failure(description: "gzip output buffer exceeds its size limit")
        }
        var output = Data(count: Int(capacity))
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else {
            throw Failure(description: "gzip compression failed: \(status)")
        }
        output.count = Int(stream.total_out)
        return output
    }
}
