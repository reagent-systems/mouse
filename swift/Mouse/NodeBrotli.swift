import Compression
import Foundation

/// Brotli for the Node layer (system.md phase G): `zlib.brotliCompress` and friends.
///
/// The refusal here said "no libbrotli/libzstd on the device: refuse rather than pretend". Half
/// of that is wrong, and a surface sweep is what caught it: Apple's **Compression** framework has
/// shipped `COMPRESSION_BROTLI` since iOS 15, right next to the LZFSE/LZ4/LZMA algorithms. zstd
/// still has no system implementation, so that half of the refusal stands.
///
/// Note the deliberate split from `zlib`, which uses libz directly: libz is used there because
/// GitCore needs exact zlib-member framing, which Compression's zlib mode does not expose.
/// Brotli has no such requirement, so the system framework is the right tool.
///
/// `compression_stream` drives both the one-shot and the incremental forms — one code path, and
/// decompression needs the streaming shape anyway since the output size is unknown up front.
final class BrotliStream {

    // compression_stream is a C struct with no zero-arg initialiser in Swift; the values are
    // overwritten by compression_stream_init immediately.
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                            dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                            src_size: 0,
                                            state: nil)
    private var initialized = false
    private let operation: compression_stream_operation
    /// Compression's destination buffer. 64 KB is a compromise: large enough that most payloads
    /// finish in one pass, small enough not to matter per stream.
    private static let bufferSize = 64 * 1024
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

    init?(compressing: Bool) {
        operation = compressing ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE
        let status = compression_stream_init(&stream, operation, COMPRESSION_BROTLI)
        guard status == COMPRESSION_STATUS_OK else {
            buffer.deallocate()
            return nil
        }
        initialized = true
    }

    deinit {
        if initialized { compression_stream_destroy(&stream) }
        buffer.deallocate()
    }

    /// Feed `input` and return whatever comes out. `finish` closes the stream, which for brotli
    /// is what writes the final block — a compressor never flushed produces nothing usable.
    /// Returns nil on a corrupt stream, which is how `brotliDecompressSync` reports bad input.
    func push(_ input: Data, finish: Bool) -> Data? {
        guard initialized else { return nil }
        var output = Data()
        let flags = finish ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

        // The input pointer must stay valid across the whole loop, so the body lives inside
        // withUnsafeBytes rather than re-entering it per pass.
        let result: Data? = input.withUnsafeBytes { raw -> Data? in
            let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            stream.src_ptr = base ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = raw.count

            while true {
                stream.dst_ptr = buffer
                stream.dst_size = Self.bufferSize
                let status = compression_stream_process(&stream, flags)
                let produced = Self.bufferSize - stream.dst_size
                if produced > 0 { output.append(buffer, count: produced) }

                switch status {
                case COMPRESSION_STATUS_OK:
                    // More room needed, or more input wanted. Nothing left to give and not
                    // finishing means this call is done.
                    if stream.src_size == 0, produced == 0 { return output }
                    if stream.src_size == 0, !finish { return output }
                    continue
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    return nil
                }
            }
        }
        return result
    }

    /// One shot: everything in, everything out, stream closed.
    static func transform(_ input: Data, compressing: Bool) -> Data? {
        guard let stream = BrotliStream(compressing: compressing) else { return nil }
        return stream.push(input, finish: true)
    }
}
