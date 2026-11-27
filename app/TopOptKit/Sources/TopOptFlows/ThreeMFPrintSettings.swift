// ThreeMFPrintSettings.swift — ★ notes30 (his word 11-26 12:50, relayed by TOReview): "the print parameters the user set should
// automatically be passed to the 3mf/stl when exporting". They are set at every import (the PRINT PARAMETERS sheet) and kept on
// the project (`PrintParams`); every 3MF the app hands out now carries them.
//
// WHERE A SLICER READS SETTINGS IN A 3MF (read from the slicers' own source, 11-27):
//   * Bambu Studio / OrcaSlicer: Metadata/project_settings.config (JSON: the WHOLE printer + filament + process profile) and
//     Metadata/model_settings.config (XML: each object's own overrides, `<object id="1"><metadata key="wall_loops" value="3"/>`).
//     Bambu Studio (2.08, his) keeps them only from a 3MF Bambu Studio wrote itself (the model's "Application" metadata starts
//     "BambuStudio-"): for any other 3MF it says "The 3mf file has invalid config, load geometry data only" and clears every
//     object's settings (Plater.cpp load_files: `!check_project_config` → load_config = false → `else if (!load_config)`
//     config.reset()). The painted supports survive that (they are mesh data, not settings).
//   * PrusaSlicer: Metadata/Slic3r_PE.config (INI: the whole profile) and Metadata/Slic3r_PE_model.config (XML: each object's
//     overrides, `<metadata type="object" key="perimeters" value="3"/>` beside its volume list), kept from any 3MF.
// So the settings go in as EACH OBJECT'S OVERRIDES, in both slicers' files — the same two files core's painted supports use
// (threemf_stream.cpp) — and never as a whole profile, which would replace the printer and filament picked in the slicer with
// guesses. What goes in: layer height, wall loops, top and bottom shell layers, infill density and pattern, outer and inner
// wall line widths. Not the material (a filament profile is the slicer's own) and not the strut width (no slicer setting).
//
// THE GEOMETRY IS NEVER REWRITTEN: every zip entry before the settings files keeps its bytes (the model part with its painted
// triangles among them); the settings files are merged (core's support lines kept) and written after, then a new index. An STL
// carries no settings and no slicer reads a note beside one, so an STL goes out as it is.
import Foundation
import Compression

public enum ThreeMFPrintSettings {
    public static let bambuFile = "Metadata/model_settings.config"
    public static let prusaFile = "Metadata/Slic3r_PE_model.config"
    static let modelFile = "3D/3dmodel.model"

    /// RED CONTROL (tests): as before notes30 — the 3MF goes out with no print settings in it.
    nonisolated(unsafe) public static var controlNoSettings = false

    public struct Setting: Equatable { public let key: String; public let value: String }

    /// Bambu Studio / OrcaSlicer's names (their process profile's keys, checked in Bambu Studio 2.08's own build).
    public static func bambu(_ p: PrintParams) -> [Setting] {
        [.init(key: "layer_height", value: mm(p.layerHeightMM)),
         .init(key: "wall_loops", value: "\(p.wallLoops)"),
         .init(key: "top_shell_layers", value: "\(p.topLayers)"),
         .init(key: "bottom_shell_layers", value: "\(p.bottomLayers)"),
         .init(key: "sparse_infill_density", value: "\(p.infillPercent)%"),
         .init(key: "sparse_infill_pattern", value: pattern(p.infillPattern)),
         .init(key: "outer_wall_line_width", value: mm(p.wallLineWidthOuterMM)),
         .init(key: "inner_wall_line_width", value: mm(p.wallLineWidthInnerMM))]
    }

    /// PrusaSlicer's names for the same settings.
    public static func prusa(_ p: PrintParams) -> [Setting] {
        [.init(key: "layer_height", value: mm(p.layerHeightMM)),
         .init(key: "perimeters", value: "\(p.wallLoops)"),
         .init(key: "top_solid_layers", value: "\(p.topLayers)"),
         .init(key: "bottom_solid_layers", value: "\(p.bottomLayers)"),
         .init(key: "fill_density", value: "\(p.infillPercent)%"),
         .init(key: "fill_pattern", value: pattern(p.infillPattern)),
         .init(key: "external_perimeter_extrusion_width", value: mm(p.wallLineWidthOuterMM)),
         .init(key: "perimeter_extrusion_width", value: mm(p.wallLineWidthInnerMM))]
    }

    /// The sheet's pattern names in the slicers' words: "lines" is "line" in both; the other five are the same word.
    static func pattern(_ s: String) -> String { s == "lines" ? "line" : s }
    static func mm(_ v: Double) -> String { String(format: "%g", (v * 1000).rounded() / 1000) }

    // MARK: - stamping a 3MF on disk

    /// One object of the model, in its order: its id, its name (as written, XML-escaped) and its triangle count.
    struct Object: Equatable { var id: Int; var name: String?; var triangles: Int }

    /// Write `settings(i)` (the model's i-th object, in its order; nil: none for that object) into the 3MF at `url`, in place.
    /// False, the file untouched: not a 3MF this can add to (no model part, a zip64 file, a part after the settings that is
    /// too big to move) or nothing to write. Throws only when writing the file failed.
    @discardableResult
    public static func stamp(_ url: URL, _ settings: (Int) -> PrintParams?) throws -> Bool {
        guard !controlNoSettings else { return false }
        // the file is read (mapped) and let go before it is cut
        let planned: (cut: Int, tail: Data)?
        do {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            planned = tailPlan(data, settings)
        }
        guard let plan = planned else { return false }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: UInt64(plan.cut))
        try h.seekToEnd()
        try h.write(contentsOf: plan.tail)
        return true
    }

    /// The same settings for every object (nil: nothing written).
    @discardableResult
    public static func stamp(_ url: URL, params: PrintParams?) throws -> Bool {
        guard let params else { return false }
        return try stamp(url) { _ in params }
    }

    /// What to write: cut the file at `cut`, then append `tail` (the moved entries, the settings files, the index).
    static func tailPlan(_ d: Data, _ settings: (Int) -> PrintParams?) -> (cut: Int, tail: Data)? {
        guard let zip = Index(d), let model = zip.entries.first(where: { $0.name == modelFile }),
              let objects = scan(d, zip, model) else { return nil }
        let stamped = objects.enumerated().compactMap { i, o in o.triangles > 0 ? settings(i).map { (o, $0) } : nil }
        guard !stamped.isEmpty else { return nil }
        let oldBambu = zip.entries.first { $0.name == bambuFile }, oldPrusa = zip.entries.first { $0.name == prusaFile }
        let replaced = [oldBambu, oldPrusa].compactMap { $0 }
        if replaced.contains(where: { zip.text(d, $0) == nil }) { return nil }   // a settings file this cannot read: left alone
        let bambu: String? = mergeBambu(oldBambu.flatMap { zip.text(d, $0) }, stamped)
        let prusa: String? = mergePrusa(oldPrusa.flatMap { zip.text(d, $0) }, stamped)
        let cut = replaced.map(\.local).min() ?? zip.cdOffset
        // the entries written after the cut that stay: moved down, byte for byte (core writes none: its settings come last)
        let kept = zip.entries.filter { e in !replaced.contains { $0.local == e.local } }
        let moved = kept.filter { $0.local >= cut }
        guard moved.reduce(0, { $0 + zip.recordLength($1) }) <= 64 << 20 else { return nil }
        var tail = Data(), central = Data()
        var offsets: [Int: Int] = [:]
        for e in moved {
            offsets[e.local] = cut + tail.count
            tail.append(d.subdata(in: e.local..<(e.local + zip.recordLength(e))))
        }
        for e in kept {
            var h = e.header
            if let o = offsets[e.local] { put32(&h, 42, UInt32(o)) }
            central.append(h)
        }
        for (name, text) in [(bambuFile, bambu), (prusaFile, prusa)] {
            guard let text else { continue }
            let body = Data(text.utf8), n = Data(name.utf8), crc = StoredZip.crc32(body)
            let at = cut + tail.count
            var local = Data()
            local.append(le32(0x0403_4b50)); local.append(le16(20)); local.append(le16(0)); local.append(le16(0))
            local.append(le16(0)); local.append(le16(0x21)); local.append(le32(crc))
            local.append(le32(UInt32(body.count))); local.append(le32(UInt32(body.count)))
            local.append(le16(UInt16(n.count))); local.append(le16(0)); local.append(n); local.append(body)
            tail.append(local)
            var h = Data()
            h.append(le32(0x0201_4b50)); h.append(le16(20)); h.append(le16(20)); h.append(le16(0)); h.append(le16(0))
            h.append(le16(0)); h.append(le16(0x21)); h.append(le32(crc)); h.append(le32(UInt32(body.count)))
            h.append(le32(UInt32(body.count))); h.append(le16(UInt16(n.count))); h.append(le16(0)); h.append(le16(0))
            h.append(le16(0)); h.append(le16(0)); h.append(le32(0)); h.append(le32(UInt32(at))); h.append(n)
            central.append(h)
        }
        let cdAt = cut + tail.count
        let count = kept.count + [bambu, prusa].compactMap { $0 }.count
        guard cdAt + central.count < Int(UInt32.max), count < 0xFFFF else { return nil }
        tail.append(central)
        tail.append(le32(0x0605_4b50)); tail.append(le16(0)); tail.append(le16(0))
        tail.append(le16(UInt16(count))); tail.append(le16(UInt16(count)))
        tail.append(le32(UInt32(central.count))); tail.append(le32(UInt32(cdAt)))
        tail.append(le16(UInt16(zip.comment.count))); tail.append(zip.comment)
        return (cut, tail)
    }

    // MARK: the two settings files

    /// Our keys, in either file (taken out before they are written again, so a second stamp replaces the first).
    static let ourKeys = Set((bambu(.fdmDefault) + prusa(.fdmDefault)).map(\.key))

    /// Metadata/model_settings.config with each stamped object's settings (core's own lines, e.g. support on, kept).
    static func mergeBambu(_ old: String?, _ stamped: [(Object, PrintParams)]) -> String {
        var text = old ?? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n</config>\n"
        for (o, p) in stamped {
            let lines = bambu(p).map { "    <metadata key=\"\($0.key)\" value=\"\(escape($0.value))\"/>\n" }.joined()
            if !insert(lines, into: &text, object: o.id, before: "<part") {
                let name = o.name.map { "    <metadata key=\"name\" value=\"\(escape(unescape($0)))\"/>\n" } ?? ""
                add("  <object id=\"\(o.id)\">\n" + name + lines + "  </object>\n", to: &text)
            }
        }
        return text
    }

    /// Metadata/Slic3r_PE_model.config: the settings ahead of each object's volume list (PrusaSlicer builds an object's
    /// volumes from this file, so a new object here names all its triangles, as core's does).
    static func mergePrusa(_ old: String?, _ stamped: [(Object, PrintParams)]) -> String {
        var text = old ?? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n</config>\n"
        for (o, p) in stamped {
            let lines = prusa(p).map { "  <metadata type=\"object\" key=\"\($0.key)\" value=\"\(escape($0.value))\"/>\n" }.joined()
            if !insert(lines, into: &text, object: o.id, before: "<volume") {
                let name = o.name.map { escape(unescape($0)) }
                add(" <object id=\"\(o.id)\" instances_count=\"1\">\n"
                    + (name.map { "  <metadata type=\"object\" key=\"name\" value=\"\($0)\"/>\n" } ?? "") + lines
                    + "  <volume firstid=\"0\" lastid=\"\(o.triangles - 1)\">\n"
                    + (name.map { "   <metadata type=\"volume\" key=\"name\" value=\"\($0)\"/>\n" } ?? "")
                    + "  </volume>\n </object>\n", to: &text)
            }
        }
        return text
    }

    /// Into the object `id`'s element: our old lines out, `lines` in at the start of the line holding `before` (else just
    /// ahead of `</object>`). False: no such object here.
    static func insert(_ lines: String, into text: inout String, object id: Int, before: String) -> Bool {
        guard let open = text.range(of: "<object\\b[^>]*\\bid=\"\(id)\"[^>]*>", options: .regularExpression),
              let close = text.range(of: "</object>", range: open.upperBound..<text.endIndex) else { return false }
        let keys = ourKeys.sorted().joined(separator: "|")
        let inner = String(text[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "[ \\t]*<metadata\\b[^>]*\\bkey=\"(\(keys))\"[^>]*/>[ \\t]*\\r?\\n?", with: "",
                                  options: .regularExpression)
        let at = inner.range(of: before)?.lowerBound ?? inner.endIndex
        let lineStart = inner[..<at].lastIndex(of: "\n").map { inner.index(after: $0) } ?? at
        text.replaceSubrange(open.upperBound..<close.lowerBound, with: inner[..<lineStart] + lines + inner[lineStart...])
        return true
    }

    static func add(_ block: String, to text: inout String) {
        if let end = text.range(of: "</config>", options: .backwards) { text.insert(contentsOf: block, at: end.lowerBound) }
        else { text += block }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: the zip's index

    struct Entry {
        var name: String
        var method: Int
        var csize: Int
        var size: Int
        var local: Int
        var header: Data   // the central header, as written
    }

    struct Index {
        var entries: [Entry] = []
        var cdOffset = 0
        var comment = Data()
        /// Each local record's end: the next record's start, else the index.
        private var ends: [Int: Int] = [:]

        init?(_ d: Data) {
            guard d.count >= 22 else { return nil }
            var end = -1
            var i = d.count - 22
            while i >= Swift.max(0, d.count - 22 - 65_535) {
                if u32(d, i) == 0x0605_4b50 { end = i; break }
                i -= 1
            }
            guard end >= 0 else { return nil }
            if end >= 20, u32(d, end - 20) == 0x0706_4b50 { return nil }   // zip64: left alone
            let count = u16(d, end + 10), cdSize = u32(d, end + 12)
            cdOffset = u32(d, end + 16)
            let commentLen = u16(d, end + 20)
            guard count != 0xFFFF, cdOffset + cdSize <= end, end + 22 + commentLen <= d.count else { return nil }
            comment = d.subdata(in: (end + 22)..<(end + 22 + commentLen))
            var at = cdOffset
            for _ in 0..<count {
                guard at + 46 <= end, u32(d, at) == 0x0201_4b50 else { return nil }
                let nameLen = u16(d, at + 28), len = 46 + nameLen + u16(d, at + 30) + u16(d, at + 32)
                guard at + len <= end else { return nil }
                let local = u32(d, at + 42)
                guard local + 30 <= cdOffset, u32(d, local) == 0x0403_4b50 else { return nil }
                entries.append(Entry(name: String(decoding: d.subdata(in: (at + 46)..<(at + 46 + nameLen)), as: UTF8.self),
                                     method: u16(d, at + 10), csize: u32(d, at + 20), size: u32(d, at + 24), local: local,
                                     header: d.subdata(in: at..<(at + len))))
                at += len
            }
            let starts = entries.map(\.local).sorted()
            for (k, s) in starts.enumerated() { ends[s] = k + 1 < starts.count ? starts[k + 1] : cdOffset }
        }

        func recordLength(_ e: Entry) -> Int { (ends[e.local] ?? cdOffset) - e.local }

        /// Where the entry's bytes start (past its local header).
        func start(_ d: Data, _ e: Entry) -> Int { e.local + 30 + u16(d, e.local + 26) + u16(d, e.local + 28) }

        /// A small text entry (a settings file), stored or deflated.
        func text(_ d: Data, _ e: Entry) -> String? {
            let s = start(d, e)
            guard s + e.csize <= cdOffset else { return nil }
            let raw = d.subdata(in: s..<(s + e.csize))
            switch e.method {
            case 0: return String(data: raw, encoding: .utf8)
            case 8: return (try? (raw as NSData).decompressed(using: .zlib)).flatMap { String(data: $0 as Data, encoding: .utf8) }
            default: return nil
            }
        }
    }

    // MARK: the model's objects

    /// The model's objects in order — id, name, triangles — read as it streams (stored, or inflated a chunk at a time), so a
    /// large print file is never held unpacked. nil: a model this cannot read.
    static func scan(_ d: Data, _ zip: Index, _ e: Entry) -> [Object]? {
        let s = zip.start(d, e)
        guard s + e.csize <= zip.cdOffset else { return nil }
        var tags = TagScanner()
        let ok: Bool = d.withUnsafeBytes { all in
            let src = UnsafeRawBufferPointer(rebasing: all[s..<(s + e.csize)])
            switch e.method {
            case 0:
                var at = 0
                while at < src.count {
                    let n = Swift.min(1 << 20, src.count - at)
                    tags.feed(UnsafeRawBufferPointer(rebasing: src[at..<(at + n)]))
                    at += n
                }
                return true
            case 8: return inflate(src) { tags.feed($0) }
            default: return false
            }
        }
        tags.finish()
        return ok && !tags.objects.isEmpty ? tags.objects : nil
    }

    /// Raw deflate (zip method 8), a chunk at a time.
    static func inflate(_ src: UnsafeRawBufferPointer, _ sink: (UnsafeRawBufferPointer) -> Void) -> Bool {
        guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return false
        }
        defer { compression_stream_destroy(&stream) }
        let chunk = 1 << 20
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }
        stream.src_ptr = base
        stream.src_size = src.count
        while true {
            stream.dst_ptr = out
            stream.dst_size = chunk
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let made = chunk - stream.dst_size
            if made > 0 { sink(UnsafeRawBufferPointer(start: out, count: made)) }
            if status == COMPRESSION_STATUS_END { return true }
            guard status == COMPRESSION_STATUS_OK else { return false }
            if made == 0 && stream.src_size == 0 { return false }
        }
    }

    /// Finds `<object …>` (its id and name), counts each `<triangle …>` inside it and closes it at `</object>`.
    struct TagScanner {
        var objects: [Object] = []
        private var carry: [UInt8] = []
        private var open = false

        mutating func feed(_ bytes: UnsafeRawBufferPointer) {
            var buf = carry
            buf.append(contentsOf: bytes)
            let n = buf.count
            var keep = n
            var i = 0
            while i < n {
                guard let lt = buf[i...].firstIndex(of: 0x3C) else { break }   // '<'
                if lt + 10 > n { keep = lt; break }
                if buf[lt + 1] == 0x74, Self.at(buf, lt, "<triangle"), Self.ends(buf[lt + 9]) {
                    if open, !objects.isEmpty { objects[objects.count - 1].triangles += 1 }
                    i = lt + 9
                } else if buf[lt + 1] == 0x6F, Self.at(buf, lt, "<object"), Self.ends(buf[lt + 7]) {
                    guard let gt = buf[lt...].firstIndex(of: 0x3E) else { keep = lt; break }   // '>'
                    let tag = String(decoding: buf[lt...gt], as: UTF8.self)
                    if let id = Self.attribute(tag, "id").flatMap(Int.init) {
                        objects.append(Object(id: id, name: Self.attribute(tag, "name"), triangles: 0))
                        open = buf[gt - 1] != 0x2F   // "<object …/>" holds nothing
                    }
                    i = gt + 1
                } else if buf[lt + 1] == 0x2F, Self.at(buf, lt, "</object>") {
                    open = false
                    i = lt + 9
                } else {
                    i = lt + 1
                }
            }
            carry = keep < n ? Array(buf[keep..<n]) : []
        }

        mutating func finish() { carry = [] }

        static func at(_ b: [UInt8], _ i: Int, _ s: StaticString) -> Bool {
            let k = s.utf8CodeUnitCount
            guard i + k <= b.count else { return false }
            return s.withUTF8Buffer { u in (0..<k).allSatisfy { b[i + $0] == u[$0] } }
        }
        /// A tag name ends here (a space, a tab, a newline, '/' or '>'): "<triangles>" is not a "<triangle".
        static func ends(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2F || c == 0x3E }
        static func attribute(_ tag: String, _ name: String) -> String? {
            guard let r = tag.range(of: "\\s\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*')", options: .regularExpression) else { return nil }
            let v = tag[r].drop { $0 != "\"" && $0 != "'" }
            return String(v.dropFirst().dropLast())
        }
    }

    // MARK: little-endian

    static func u16(_ d: Data, _ i: Int) -> Int { Int(d[d.startIndex + i]) | Int(d[d.startIndex + i + 1]) << 8 }
    static func u32(_ d: Data, _ i: Int) -> Int { u16(d, i) | u16(d, i + 2) << 16 }
    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
    static func put32(_ d: inout Data, _ i: Int, _ v: UInt32) {
        let b = le32(v)
        for k in 0..<4 { d[d.startIndex + i + k] = b[b.startIndex + k] }
    }
}
