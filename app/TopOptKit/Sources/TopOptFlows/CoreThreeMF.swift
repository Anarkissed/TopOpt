// CoreThreeMF — ★ Organic cut 2 (organic-cut2-handover.md, OF5): the print file the Mac makes for an Organic lattice is a 3MF,
// written by core's own streaming writer (core/src/io/threemf_stream.cpp): a zip of three entries, the model part
// "3D/3dmodel.model" deflated (method 8, raw deflate) or stored, holding ONE object with ONE indexed mesh: its vertices as
// `<vertex x="%.6f" y="%.6f" z="%.6f"/>` lines, then its triangles as `<triangle v1="i" v2="j" v3="k"/>`. Read back here for
// the Results screen's mesh, streamed: the model part is inflated a chunk at a time and its lines scanned as they come, so the
// whole text (hundreds of MB for an Organic part) is never held at once. Any 3MF this does not understand is refused with a
// plain line; it never guesses.
import Foundation
import Compression

public enum CoreThreeMF {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
        init(_ d: String) { description = d }
    }
    static let modelName = "3D/3dmodel.model"

    /// The mesh of core's 3MF: vertices (x, y, z per vertex) and triangles (three vertex indices each).
    public static func mesh(_ data: Data) throws -> (vertices: [Float], indices: [Int32]) {
        let b = [UInt8](data)
        let entry = try modelEntry(b)
        var scan = Scanner()
        if entry.method == 0 {
            try scan.feed(b[entry.start..<(entry.start + entry.size)])
        } else {
            try inflate(b[entry.start..<(entry.start + entry.csize)], expected: entry.size) { try scan.feed($0) }
        }
        try scan.finish()
        guard !scan.indices.isEmpty, !scan.vertices.isEmpty else { throw Failure("The print file holds no triangles") }
        let n = Int32(scan.vertices.count / 3)
        guard scan.indices.allSatisfy({ $0 >= 0 && $0 < n }) else { throw Failure("The print file's triangles name missing points") }
        return (scan.vertices, scan.indices)
    }

    // MARK: the zip

    struct Entry { var method: Int; var start: Int; var csize: Int; var size: Int }

    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }

    /// The model part, found through the central directory (the end record, then each header), then its local header.
    static func modelEntry(_ b: [UInt8]) throws -> Entry {
        guard b.count >= 22 else { throw Failure("The print file is not a 3MF") }
        var end = -1
        var i = b.count - 22
        let floor = Swift.max(0, b.count - 22 - 65_535)
        while i >= floor {
            if u32(b, i) == 0x0605_4b50 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw Failure("The print file is not a 3MF") }
        let count = u16(b, end + 10), cdOffset = u32(b, end + 16)
        var at = cdOffset
        for _ in 0..<count {
            guard at + 46 <= b.count, u32(b, at) == 0x0201_4b50 else { throw Failure("The print file's index is damaged") }
            let method = u16(b, at + 10), csize = u32(b, at + 20), size = u32(b, at + 24)
            let nameLen = u16(b, at + 28), extraLen = u16(b, at + 30), commentLen = u16(b, at + 32), local = u32(b, at + 42)
            guard at + 46 + nameLen <= b.count else { throw Failure("The print file's index is damaged") }
            let name = String(decoding: b[(at + 46)..<(at + 46 + nameLen)], as: UTF8.self)
            if name == modelName {
                guard method == 0 || method == 8 else { throw Failure("The print file is packed in a way this app cannot read") }
                guard local + 30 <= b.count, u32(b, local) == 0x0403_4b50 else { throw Failure("The print file's model is damaged") }
                let start = local + 30 + u16(b, local + 26) + u16(b, local + 28)
                guard start + (method == 0 ? size : csize) <= b.count else { throw Failure("The print file is cut short") }
                return Entry(method: method, start: start, csize: csize, size: size)
            }
            at += 46 + nameLen + extraLen + commentLen
        }
        throw Failure("The print file has no model in it")
    }

    /// Raw deflate (RFC 1951, as zlib's -15 window writes it), a chunk at a time.
    static func inflate(_ src: ArraySlice<UInt8>, expected: Int, _ sink: (ArraySlice<UInt8>) throws -> Void) throws {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure("The print file could not be unpacked")
        }
        defer { compression_stream_destroy(&stream) }
        let chunk = 1 << 20
        var out = [UInt8](repeating: 0, count: chunk)
        var total = 0
        try src.withUnsafeBufferPointer { inBuf in
            stream.src_ptr = inBuf.baseAddress!
            stream.src_size = inBuf.count
            while true {
                let status: compression_status = out.withUnsafeMutableBufferPointer { o in
                    stream.dst_ptr = o.baseAddress!
                    stream.dst_size = chunk
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let made = chunk - stream.dst_size
                if made > 0 { total += made; try sink(out[0..<made]) }
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw Failure("The print file could not be unpacked") }
                if made == 0 && stream.src_size == 0 { break }
            }
        }
        guard total == expected else { throw Failure("The print file unpacked to the wrong size") }
    }

    // MARK: the model's lines

    /// Scans the model text as it streams in: each `<vertex .../>` and `<triangle .../>` element (core writes one a line).
    struct Scanner {
        var vertices: [Float] = []
        var indices: [Int32] = []
        private var carry: [UInt8] = []

        mutating func feed(_ bytes: ArraySlice<UInt8>) throws {
            var buf = carry
            buf.append(contentsOf: bytes)
            var lineStart = 0
            var i = 0
            let n = buf.count
            while i < n {
                if buf[i] == 0x0A {   // \n
                    try line(buf, lineStart, i)
                    lineStart = i + 1
                }
                i += 1
            }
            carry = Array(buf[lineStart..<n])
        }

        mutating func finish() throws {
            if !carry.isEmpty { try line(carry, 0, carry.count) }
            carry = []
        }

        /// One line: a vertex or a triangle, else nothing.
        private mutating func line(_ b: [UInt8], _ from: Int, _ to: Int) throws {
            var i = from
            while i < to && (b[i] == 0x20 || b[i] == 0x09) { i += 1 }
            guard i + 8 < to, b[i] == 0x3C else { return }   // '<'
            if b[i + 1] == 0x76, starts(b, i, "<vertex ") {
                var p = i + 8
                for _ in 0..<3 {
                    guard let q = Self.quote(b, &p, to) else { throw Failure("The print file has a point it cannot read") }
                    vertices.append(Float(Self.number(b, q.0, q.1)))
                }
            } else if b[i + 1] == 0x74, starts(b, i, "<triangle ") {
                var p = i + 10
                for _ in 0..<3 {
                    guard let q = Self.quote(b, &p, to) else { throw Failure("The print file has a triangle it cannot read") }
                    var v = 0
                    for k in q.0..<q.1 {
                        let d = Int(b[k]) - 48
                        guard d >= 0 && d <= 9 else { throw Failure("The print file has a triangle it cannot read") }
                        v = v * 10 + d
                    }
                    guard v <= Int(Int32.max) else { throw Failure("The print file is too large to show") }
                    indices.append(Int32(v))
                }
            }
        }

        private func starts(_ b: [UInt8], _ i: Int, _ s: StaticString) -> Bool {
            let n = s.utf8CodeUnitCount
            guard i + n <= b.count else { return false }
            return s.withUTF8Buffer { u in (0..<n).allSatisfy { b[i + $0] == u[$0] } }
        }

        /// The next quoted value from `p` on: (its first byte, one past its last); `p` moves past it.
        static func quote(_ b: [UInt8], _ p: inout Int, _ to: Int) -> (Int, Int)? {
            while p < to && b[p] != 0x22 { p += 1 }
            guard p < to else { return nil }
            let s = p + 1
            var e = s
            while e < to && b[e] != 0x22 { e += 1 }
            guard e < to else { return nil }
            p = e + 1
            return (s, e)
        }

        /// A plain decimal ("-12.345678", as %.6f writes it; an exponent too, for safety).
        static func number(_ b: [UInt8], _ s: Int, _ e: Int) -> Double {
            var i = s
            var neg = false
            if i < e && (b[i] == 0x2D || b[i] == 0x2B) { neg = b[i] == 0x2D; i += 1 }
            var v = 0.0
            while i < e, b[i] >= 0x30, b[i] <= 0x39 { v = v * 10 + Double(b[i] - 0x30); i += 1 }
            if i < e && b[i] == 0x2E {
                i += 1
                var scale = 0.1
                while i < e, b[i] >= 0x30, b[i] <= 0x39 { v += Double(b[i] - 0x30) * scale; scale *= 0.1; i += 1 }
            }
            if i < e && (b[i] == 0x65 || b[i] == 0x45) {
                i += 1
                var eneg = false
                if i < e && (b[i] == 0x2D || b[i] == 0x2B) { eneg = b[i] == 0x2D; i += 1 }
                var x = 0
                while i < e, b[i] >= 0x30, b[i] <= 0x39 { x = x * 10 + Int(b[i] - 0x30); i += 1 }
                v *= pow(10, Double(eneg ? -x : x))
            }
            return neg ? -v : v
        }
    }
}
