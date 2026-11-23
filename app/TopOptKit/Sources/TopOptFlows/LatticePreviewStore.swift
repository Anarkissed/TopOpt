// LatticePreviewStore.swift — ★ his iPad notes 2026-11-23 (RESULTS_REPORT §7):
//   "When I open up an old Lattice job, the previous preview should be visible and all the settings should already be saved.
//    Currently it resets the Lattice settings each time I jump into a version requiring that I wait for the lattice to be
//    re-made. This is wasted time."
//
// The laid lattice preview and the stress check it follows lived only in memory (LatticeLayoutPreview's `remembered`,
// LatticeSimModel's field). Now each version's folder keeps the last of each, in binary (a 90k-strut Organic lattice saves and
// reads back in well under a second — never JSON):
//   * lattice_preview.bin — what the preview drew (the bars, the vines, the solid view's map, the colour key's cells), the
//     Organic groups and their asks (what the print file is made from), the walls, Auto's numbers, the lines; keyed by the
//     inputs that laid it (LatticeLayoutPreview.LayInputs: the settings as core reads them, the lattice settings, the page's
//     view pick, the flush faces, the layer, the regions and groups, and the stress — its reference and its field, by a
//     signature of its values, never the run-time key);
//   * stress_check.bin — the stress check's field (von Mises and the full tensor the Organic session is given), its numbers,
//     keyed by the check's own inputs (LatticeSimFingerprint, the model's path left out: the folder is the version's).
// On open, when the inputs are the same, the page shows the saved lattice at once and the session gets its tensor back (no
// stress check, no lay); when they are not, it lays as before. The model's own path is never part of a key (an app update
// moves the app's folder).
import Foundation
import simd
import TopOptKit

// MARK: - binary

/// Little-endian, length-prefixed. Plain arrays are copied whole (memcpy), never value by value.
struct PreviewBinWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }
    mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func int(_ v: Int) { u64(UInt64(bitPattern: Int64(v))) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func str(_ s: String) { let b = Array(s.utf8); int(b.count); data.append(contentsOf: b) }
    mutating func optStr(_ s: String?) { bool(s != nil); if let s { str(s) } }
    mutating func bytes(_ d: Data) { int(d.count); data.append(d) }
    mutating func v3(_ v: SIMD3<Float>) { f32(v.x); f32(v.y); f32(v.z) }
    mutating func v3d(_ v: SIMD3<Double>) { f64(v.x); f64(v.y); f64(v.z) }
    /// A plain array (Float, Double, Int32, UInt8, Int8), whole.
    mutating func pod<T>(_ a: [T]) {
        int(a.count)
        a.withUnsafeBytes { data.append(contentsOf: $0) }
    }
}

struct PreviewBinReader {
    enum Bad: Error { case short, form }
    let data: Data
    var at = 0
    init(_ data: Data) { self.data = data }

    private mutating func raw<T>(_: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard at + n <= data.count else { throw Bad.short }
        var v: T? = nil
        data.withUnsafeBytes { src in
            withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { tmp in
                memcpy(tmp.baseAddress!, src.baseAddress! + at, n)
                v = tmp[0]
            }
        }
        at += n
        return v!
    }
    mutating func u8() throws -> UInt8 { try raw(UInt8.self) }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func u32() throws -> UInt32 { UInt32(littleEndian: try raw(UInt32.self)) }
    mutating func u64() throws -> UInt64 { UInt64(littleEndian: try raw(UInt64.self)) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func int() throws -> Int { Int(Int64(bitPattern: try u64())) }
    mutating func count(_ stride: Int = 1) throws -> Int {
        let n = try int()
        guard n >= 0, n <= (data.count - at) / Swift.max(1, stride) + 1 else { throw Bad.form }
        return n
    }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    mutating func str() throws -> String {
        let n = try count()
        guard at + n <= data.count else { throw Bad.short }
        let s = String(decoding: data[data.startIndex + at ..< data.startIndex + at + n], as: UTF8.self)
        at += n
        return s
    }
    mutating func optStr() throws -> String? { try bool() ? try str() : nil }
    mutating func bytes() throws -> Data {
        let n = try count()
        guard at + n <= data.count else { throw Bad.short }
        let d = data.subdata(in: data.startIndex + at ..< data.startIndex + at + n)
        at += n
        return d
    }
    mutating func v3() throws -> SIMD3<Float> { SIMD3(try f32(), try f32(), try f32()) }
    mutating func v3d() throws -> SIMD3<Double> { SIMD3(try f64(), try f64(), try f64()) }
    mutating func pod<T>(_: T.Type) throws -> [T] {
        let stride = MemoryLayout<T>.stride
        let n = try count(stride)
        let bytes = n * stride
        guard at + bytes <= data.count else { throw Bad.short }
        let out = [T](unsafeUninitializedCapacity: n) { buf, made in
            if bytes > 0 {
                data.withUnsafeBytes { src in memcpy(UnsafeMutableRawPointer(buf.baseAddress!), src.baseAddress! + at, bytes) }
            }
            made = n
        }
        at += bytes
        return out
    }
}

// MARK: - the store

enum LatticePreviewStore {
    static let fileName = "lattice_preview.bin"
    static let stressFileName = "stress_check.bin"
    static let magic: UInt32 = 0x504C_4F54   // "TOLP"
    static let stressMagic: UInt32 = 0x5353_4F54   // "TOSS"
    static let formatVersion: UInt32 = 1
    /// RED CONTROL (LatticePreviewStoreTests): nothing is saved or read back (every open lays again, as before 11-23).
    nonisolated(unsafe) static var controlNoStore = false
    /// A test's count: lattices shown from a version's folder.
    nonisolated(unsafe) static var restoredFromDisk = 0

    /// The version's folder the model at `path` is in (the store's copy, beside its project.json); nil for any other file.
    static func folder(forModelPath path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.json").path) ? dir : nil
    }

    // MARK: the key

    /// What a saved lattice was laid from, in a form that reads back the same in any later launch.
    struct Key: Equatable {
        var settings: String          // core's settings, written out whole (no dictionary in them: always the same text)
        var lattice: LatticeSettings
        var pageManual: Bool
        var flush: [Int32]
        var layer: Double
        var keys: [Int32: String]
        var groups: [Int32: UUID]
        var groupOrder: [UUID]
        var referenceMPa: Double
        var field: UInt64             // the stress field's values' signature (0: none)
    }

    static func key(_ i: LatticeLayoutPreview.LayInputs) -> Key {
        Key(settings: String(reflecting: i.settings), lattice: i.lattice, pageManual: i.pageManual, flush: i.flush,
            layer: i.layer, keys: i.keys, groups: i.groups, groupOrder: i.groupOrder, referenceMPa: i.stress.referenceMPa,
            field: fieldSignature(i.stress.field))
    }

    /// A signature of the field's values (the same field: the same number, in every launch).
    static func fieldSignature(_ f: LatticeDemandField?) -> UInt64 {
        guard let f else { return 0 }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ v: UInt64) { h = (h ^ v) &* 0x100_0000_01b3; h ^= h >> 29 }
        mix(UInt64(f.nx)); mix(UInt64(f.ny)); mix(UInt64(f.nz))
        mix(f.origin.x.bitPattern); mix(f.origin.y.bitPattern); mix(f.origin.z.bitPattern); mix(f.spacingMM.bitPattern)
        mix(UInt64(f.vonMises.count)); mix(UInt64(f.stressTensor.count))
        f.vonMises.withUnsafeBufferPointer { b in for v in b { mix(UInt64(v.bitPattern)) } }
        f.stressTensor.withUnsafeBufferPointer { b in for v in b { mix(v.bitPattern) } }
        return h == 0 ? 1 : h
    }

    static func putKey(_ k: Key, _ w: inout PreviewBinWriter) {
        w.str(k.settings)
        w.bytes((try? JSONEncoder().encode(k.lattice)) ?? Data())
        w.bool(k.pageManual); w.pod(k.flush); w.f64(k.layer)
        let keys = k.keys.sorted { $0.key < $1.key }
        w.int(keys.count); for (r, s) in keys { w.i32(r); w.str(s) }
        let groups = k.groups.sorted { $0.key < $1.key }
        w.int(groups.count); for (r, g) in groups { w.i32(r); w.str(g.uuidString) }
        w.int(k.groupOrder.count); for g in k.groupOrder { w.str(g.uuidString) }
        w.f64(k.referenceMPa); w.u64(k.field)
    }

    static func getKey(_ r: inout PreviewBinReader) throws -> Key {
        let settings = try r.str()
        let lattice = try JSONDecoder().decode(LatticeSettings.self, from: try r.bytes())
        let pageManual = try r.bool(), flush = try r.pod(Int32.self), layer = try r.f64()
        var keys: [Int32: String] = [:]
        for _ in 0..<(try r.count(9)) { let id = try r.i32(); keys[id] = try r.str() }
        var groups: [Int32: UUID] = [:]
        for _ in 0..<(try r.count(9)) { let id = try r.i32(); groups[id] = UUID(uuidString: try r.str()) }
        var order: [UUID] = []
        for _ in 0..<(try r.count(8)) { if let g = UUID(uuidString: try r.str()) { order.append(g) } }
        return Key(settings: settings, lattice: lattice, pageManual: pageManual, flush: flush, layer: layer, keys: keys,
                   groups: groups, groupOrder: order, referenceMPa: try r.f64(), field: try r.u64())
    }

    // MARK: the preview: encode / decode

    /// The remembered lattice, whole, in binary. nil: a part of it this format cannot hold (it would not read back the same).
    static func encode(_ m: LatticeLayoutPreview.Remembered) -> Data? {
        var w = PreviewBinWriter()
        w.u32(magic); w.u32(formatVersion)
        putKey(key(m.inputs), &w)
        w.u8(m.quality == .draft ? 1 : 0)
        w.int(m.struts)
        w.optStr(m.problem)
        w.int(m.notes.count); for n in m.notes { w.str(n) }
        // timing
        w.bool(m.timing != nil)
        if let t = m.timing {
            w.f64(t.openMS); w.f64(t.readMS); w.f64(t.cellsMS); w.f64(t.barsMS); w.int(t.bars); w.f64(t.mapMS); w.optStr(t.organicLine)
        }
        w.bool(m.numbers != nil)
        if let n = m.numbers { w.int(n.strands); w.int(n.segments); w.f64(n.ms); w.bool(n.draft); w.bool(n.limitsMeasured) }
        w.int(m.walls.count); for x in m.walls { w.i32(x.region); w.int(x.foci) }
        let verdicts = m.wallVerdicts.sorted { $0.key < $1.key }
        w.int(verdicts.count); for (k, v) in verdicts { w.str(k); w.bool(v) }
        w.bool(m.autoLimits != nil); if let l = m.autoLimits { putLimits(l, &w) }
        let gl = m.groupLimits.sorted { $0.key.uuidString < $1.key.uuidString }
        w.int(gl.count); for (g, l) in gl { w.str(g.uuidString); putLimits(l, &w) }
        w.int(m.groups.count)
        for g in m.groups { w.pod(g.regions); putOrganic(g.ask, &w) }
        // what is drawn
        let b = m.bars
        w.pod(b.bars); w.pod(b.flags); w.int(b.lightFrom == .max ? -1 : b.lightFrom); w.bool(b.hidden)
        w.bool(b.solid != nil)
        if let s = b.solid { w.v3(s.origin); w.f32(s.voxel); w.i32(s.dims.x); w.i32(s.dims.y); w.i32(s.dims.z); w.pod(s.rg); w.bool(s.smooth) }
        w.bool(b.vines != nil); if let v = b.vines { putVines(v, &w) }
        w.bool(m.laid != nil)
        if let l = m.laid {
            let same = l.bars == b.bars
            w.bool(same); if !same { w.pod(l.bars) }
            w.pod(l.barFlags); w.pod(l.barCell); w.pod(l.barRegion); w.pod(l.frames); w.pod(l.cellInfo); w.pod(l.cellRegion)
            w.pod(l.cellWall); w.pod(l.cellFrame); w.pod(l.cellLo); w.pod(l.cellWallMM)
        }
        return w.data
    }

    /// The saved lattice read back for `current` (the inputs this page would lay now), or nil: another lattice's, or
    /// unreadable. Its token is the caller's (a fresh one).
    static func decode(_ data: Data, for current: LatticeLayoutPreview.LayInputs, token: Int) -> LatticeLayoutPreview.Remembered? {
        var r = PreviewBinReader(data)
        do {
            guard try r.u32() == magic, try r.u32() == formatVersion else { return nil }
            guard try getKey(&r) == key(current) else { return nil }
            let quality: LatticeLayoutSession.Organic.Quality = try r.u8() == 1 ? .draft : .exact
            let struts = try r.int()
            let problem = try r.optStr()
            var notes: [String] = []
            for _ in 0..<(try r.count(8)) { notes.append(try r.str()) }
            var timing: LatticeLayoutPreview.Timing?
            if try r.bool() {
                var t = LatticeLayoutPreview.Timing(openMS: try r.f64(), readMS: try r.f64(), cellsMS: try r.f64(), barsMS: try r.f64(),
                                                    bars: try r.int())
                t.mapMS = try r.f64(); t.organicLine = try r.optStr()
                timing = t
            }
            var numbers: LatticeLayoutPreview.OrganicNumbers?
            if try r.bool() {
                numbers = .init(strands: try r.int(), segments: try r.int(), ms: try r.f64(), draft: try r.bool(),
                                limitsMeasured: try r.bool())
            }
            var walls: [(region: Int32, foci: Int)] = []
            for _ in 0..<(try r.count(12)) { walls.append((try r.i32(), try r.int())) }
            var verdicts: [String: Bool] = [:]
            for _ in 0..<(try r.count(9)) { let k = try r.str(); verdicts[k] = try r.bool() }
            let auto = try r.bool() ? try getLimits(&r) : nil
            var groupLimits: [UUID: LatticeOrganicLook.Limits] = [:]
            for _ in 0..<(try r.count(9)) {
                let g = UUID(uuidString: try r.str()); let l = try getLimits(&r)
                if let g { groupLimits[g] = l }
            }
            var groups: [LatticeLayoutSession.OrganicGroup] = []
            for _ in 0..<(try r.count(8)) { groups.append(.init(regions: try r.pod(Int32.self), ask: try getOrganic(&r))) }
            let barsF = try r.pod(Float.self), flags = try r.pod(UInt8.self)
            let light = try r.int(), hidden = try r.bool()
            var bars = LatticeLayoutBarsInputs(token: token, bars: barsF, hidden: hidden, flags: flags)
            bars.lightFrom = light < 0 ? .max : light
            if try r.bool() {
                let origin = try r.v3(), voxel = try r.f32()
                let dims = SIMD3<Int32>(try r.i32(), try r.i32(), try r.i32())
                bars.solid = LatticeLayoutSolidGrid(token: token, origin: origin, voxel: voxel, dims: dims, rg: try r.pod(Int8.self),
                                                    smooth: try r.bool())
            }
            if try r.bool() { bars.vines = try getVines(&r) }
            var laid: LatticeLayoutColours.Laid?
            if try r.bool() {
                var l = LatticeLayoutColours.Laid()
                l.bars = try r.bool() ? barsF : try r.pod(Float.self)
                l.barFlags = try r.pod(UInt8.self); l.barCell = try r.pod(Float.self); l.barRegion = try r.pod(Int32.self)
                l.frames = try r.pod(Float.self); l.cellInfo = try r.pod(Float.self); l.cellRegion = try r.pod(Int32.self)
                l.cellWall = try r.pod(Int32.self); l.cellFrame = try r.pod(Int32.self); l.cellLo = try r.pod(Float.self)
                l.cellWallMM = try r.pod(Float.self)
                l.token = token
                laid = l
            }
            return LatticeLayoutPreview.Remembered(inputs: current, bars: bars, laid: laid, timing: timing, numbers: numbers,
                                                   problem: problem, notes: notes, groups: groups, walls: walls,
                                                   wallVerdicts: verdicts, autoLimits: auto, groupLimits: groupLimits,
                                                   struts: struts, quality: quality)
        } catch {
            return nil
        }
    }

    /// Whether the saved lattice reads back as it was (every part the print file and the drawing use): a field this format
    /// does not know yet (a new Organic setting, a new vine part) fails here, and nothing is saved rather than a wrong one.
    static func readsBack(_ data: Data, _ m: LatticeLayoutPreview.Remembered) -> Bool {
        guard let back = decode(data, for: m.inputs, token: m.bars.token) else { return false }
        return back.groups.map(\.ask) == m.groups.map(\.ask) && back.groups.map(\.regions) == m.groups.map(\.regions)
            && back.bars.vines == m.bars.vines && back.bars.bars == m.bars.bars && back.bars.flags == m.bars.flags
            && back.bars.solid?.rg == m.bars.solid?.rg && back.laid?.barCell == m.laid?.barCell
            && back.laid?.barRegion == m.laid?.barRegion && back.autoLimits == m.autoLimits && back.groupLimits == m.groupLimits
            && back.timing == m.timing && back.numbers == m.numbers && back.notes == m.notes && back.problem == m.problem
    }

    // MARK: the preview: on disk

    private static let queue = DispatchQueue(label: "app.topopt.lattice-preview-store", qos: .utility)
    @MainActor private static var pending: [String: LatticeLayoutPreview.Remembered] = [:]
    /// How long a save waits for the next (the solid view's map lands just after the lay): the last one is written.
    static let saveWaitS = 0.8
    private final class Box: @unchecked Sendable { let m: LatticeLayoutPreview.Remembered; init(_ m: LatticeLayoutPreview.Remembered) { self.m = m } }

    /// Keep `m` as its version's last lattice (written off the main thread, the last of a quick run of saves).
    @MainActor static func save(_ m: LatticeLayoutPreview.Remembered) {
        guard !controlNoStore, let dir = folder(forModelPath: m.inputs.path) else { return }
        let k = dir.path
        let first = pending[k] == nil
        pending[k] = m
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + saveWaitS) {
            guard let m = pending.removeValue(forKey: k) else { return }
            write(m, to: dir)
        }
    }

    /// Written now, off the main thread (`done` on the main thread when it landed or was refused).
    @MainActor static func write(_ m: LatticeLayoutPreview.Remembered, to dir: URL, done: (@MainActor (Bool) -> Void)? = nil) {
        let box = Box(m)
        queue.async {
            var ok = false
            if let data = encode(box.m), readsBack(data, box.m),
               FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.json").path) {
                ok = (try? data.write(to: dir.appendingPathComponent(fileName), options: .atomic)) != nil
            }
            DispatchQueue.main.async { done?(ok) }
        }
    }

    /// The lattice saved beside the model at `current.path` when it was laid from exactly these inputs; nil otherwise.
    static func load(_ current: LatticeLayoutPreview.LayInputs, token: Int) -> LatticeLayoutPreview.Remembered? {
        guard !controlNoStore, let dir = folder(forModelPath: current.path),
              let data = try? Data(contentsOf: dir.appendingPathComponent(fileName), options: .mappedIfSafe) else { return nil }
        return decode(data, for: current, token: token)
    }

    /// A new version made from `from` with the same settings takes its saved lattice (and stress check) along.
    static func copy(from: UUID, to: UUID, store: ProjectStore) {
        let a = store.rootDir.appendingPathComponent(from.uuidString), b = store.rootDir.appendingPathComponent(to.uuidString)
        for f in [fileName, stressFileName] {
            let src = a.appendingPathComponent(f), dst = b.appendingPathComponent(f)
            guard FileManager.default.fileExists(atPath: src.path), !FileManager.default.fileExists(atPath: dst.path) else { continue }
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }

    // MARK: the stress check

    struct SavedStress {
        var field: LatticeDemandField
        var summary: LatticeSimModel.Summary
        var unsolved: [String]
    }

    /// The check's inputs as a key, the model's path left out (the folder is the version's).
    static func stressKey(_ fp: LatticeSimFingerprint) -> String {
        String(reflecting: LatticeSimFingerprint(modelPath: "", material: fp.material, resolution: fp.resolution,
                                                  anchorFaceIDs: fp.anchorFaceIDs, loadGroups: fp.loadGroups,
                                                  anchorRegionIDs: fp.anchorRegionIDs, regionSignature: fp.regionSignature))
    }

    static func encodeStress(_ s: SavedStress, key: String) -> Data {
        var w = PreviewBinWriter()
        w.u32(stressMagic); w.u32(formatVersion)
        w.str(key)
        let f = s.field
        w.int(f.nx); w.int(f.ny); w.int(f.nz); w.v3d(f.origin); w.f64(f.spacingMM)
        w.pod(f.vonMises); w.pod(f.stressTensor)
        if case let .solidSim(date, res) = f.provenance { w.f64(date.timeIntervalSince1970); w.int(res) } else { w.f64(0); w.int(0) }
        let m = s.summary
        w.f64(m.maxDisplacementMM); w.f64(m.maxStressMPa); w.f64(m.safety); w.f64(m.date.timeIntervalSince1970); w.int(m.resolution)
        w.int(s.unsolved.count); for u in s.unsolved { w.str(u) }
        return w.data
    }

    static func decodeStress(_ data: Data, key: String) -> SavedStress? {
        var r = PreviewBinReader(data)
        do {
            guard try r.u32() == stressMagic, try r.u32() == formatVersion, try r.str() == key else { return nil }
            let nx = try r.int(), ny = try r.int(), nz = try r.int()
            let origin = try r.v3d(), spacing = try r.f64()
            let vm = try r.pod(Float.self), t = try r.pod(Double.self)
            let date = Date(timeIntervalSince1970: try r.f64()), res = try r.int()
            let field = LatticeDemandField(vonMises: vm, stressTensor: t, nx: nx, ny: ny, nz: nz, origin: origin, spacingMM: spacing,
                                           provenance: .solidSim(date: date, resolution: res))
            let summary = LatticeSimModel.Summary(maxDisplacementMM: try r.f64(), maxStressMPa: try r.f64(), safety: try r.f64(),
                                                  date: Date(timeIntervalSince1970: try r.f64()), resolution: try r.int())
            var unsolved: [String] = []
            for _ in 0..<(try r.count(8)) { unsolved.append(try r.str()) }
            guard vm.count == nx * ny * nz, t.isEmpty || t.count == 6 * vm.count else { return nil }
            return SavedStress(field: field, summary: summary, unsolved: unsolved)
        } catch {
            return nil
        }
    }

    /// The check just made, kept in its version's folder (off the main thread).
    static func saveStress(_ s: SavedStress, fingerprint fp: LatticeSimFingerprint) {
        guard !controlNoStore, let dir = folder(forModelPath: fp.modelPath) else { return }
        let key = stressKey(fp)
        let box = StressBox(s)
        queue.async {
            let data = encodeStress(box.s, key: key)
            try? data.write(to: dir.appendingPathComponent(stressFileName), options: .atomic)
        }
    }
    private final class StressBox: @unchecked Sendable { let s: SavedStress; init(_ s: SavedStress) { self.s = s } }

    /// The check saved for exactly these inputs, or nil.
    static func loadStress(_ fp: LatticeSimFingerprint) -> SavedStress? {
        guard !controlNoStore, let dir = folder(forModelPath: fp.modelPath),
              let data = try? Data(contentsOf: dir.appendingPathComponent(stressFileName), options: .mappedIfSafe) else { return nil }
        return decodeStress(data, key: stressKey(fp))
    }

    /// Waits for the store's queued writes (tests).
    static func flush() { queue.sync {} }
}

// MARK: - the parts, one by one

extension LatticePreviewStore {
    static func putLimits(_ l: LatticeOrganicLook.Limits, _ w: inout PreviewBinWriter) {
        w.f64(l.strutLowerMM); w.f64(l.strutUpperMM); w.f64(l.strutAutoMM)
        w.f64(l.cellLowerMM); w.f64(l.cellUpperMM); w.f64(l.cellAutoMM); w.bool(l.measured); w.f64(l.gapMM)
    }
    static func getLimits(_ r: inout PreviewBinReader) throws -> LatticeOrganicLook.Limits {
        .init(strutLowerMM: try r.f64(), strutUpperMM: try r.f64(), strutAutoMM: try r.f64(), cellLowerMM: try r.f64(),
              cellUpperMM: try r.f64(), cellAutoMM: try r.f64(), measured: try r.bool(), gapMM: try r.f64())
    }

    /// The Organic ask's fields (60; LatticePreviewStoreTests pins the count, and `readsBack` refuses one this misses).
    static let organicFieldCount = 60

    static func putOrganic(_ o: LatticeLayoutSession.Organic, _ w: inout PreviewBinWriter) {
        w.i32(o.mode.rawValue); w.i32(o.quality.rawValue)
        for d in [o.toleranceMM, o.spacingMM, o.spacingMinMM, o.spacingMaxMM, o.spacingExponent, o.widthMM, o.widthHeavyMM,
                  o.referenceMPa, o.percentile] { w.f64(d) }
        w.bool(o.shapeFit); w.bool(o.memberCap); w.f64(o.shapeReach); w.v3d(o.buildDir)
        w.bool(o.wallsOut); w.bool(o.ties); w.f64(o.tieSwirl); w.f64(o.footGap); w.bool(o.stressGoal); w.f64(o.voidRatio)
        w.i32(o.reseedRounds); w.bool(o.wallConnect); w.f64(o.wallGap); w.f64(o.wallGapHeavy); w.i32(o.wallCross)
        w.f64(o.crossGap); w.f64(o.crossGapHeavy); w.f64(o.crossClimbMaxDeg); w.f64(o.topRun); w.f64(o.rootRun); w.i32(o.runMax)
        for d in [o.runGap, o.runFollow, o.runPull, o.runSeek, o.runMin, o.rootGap] { w.f64(d) }
        w.bool(o.autoByStress); w.bool(o.prune); w.f64(o.bedFloorMM); w.bool(o.holdParts); w.f64(o.partReachMM)
        w.f64(o.partSupportMM); w.bool(o.partToFloor); w.f64(o.linkWidth); w.f64(o.unbracedMax); w.bool(o.tieLevel)
        w.f64(o.tieGap); w.f64(o.tieGapHeavy); w.bool(o.followStress); w.f64(o.layerMM); w.u64(o.seed); w.f64(o.gapLines)
        w.f64(o.faceReliefMM); w.pod(o.reliefExcludeFaces); w.f64(o.strandKeep); w.f64(o.wallBareMM); w.f64(o.wallReach)
        w.bool(o.sweep)
    }

    static func getOrganic(_ r: inout PreviewBinReader) throws -> LatticeLayoutSession.Organic {
        var o = LatticeLayoutSession.Organic()
        guard let mode = LatticeLayoutSession.Organic.Mode(rawValue: try r.i32()),
              let quality = LatticeLayoutSession.Organic.Quality(rawValue: try r.i32()) else { throw PreviewBinReader.Bad.form }
        o.mode = mode; o.quality = quality
        o.toleranceMM = try r.f64(); o.spacingMM = try r.f64(); o.spacingMinMM = try r.f64(); o.spacingMaxMM = try r.f64()
        o.spacingExponent = try r.f64(); o.widthMM = try r.f64(); o.widthHeavyMM = try r.f64(); o.referenceMPa = try r.f64()
        o.percentile = try r.f64()
        o.shapeFit = try r.bool(); o.memberCap = try r.bool(); o.shapeReach = try r.f64(); o.buildDir = try r.v3d()
        o.wallsOut = try r.bool(); o.ties = try r.bool(); o.tieSwirl = try r.f64(); o.footGap = try r.f64()
        o.stressGoal = try r.bool(); o.voidRatio = try r.f64()
        o.reseedRounds = try r.i32(); o.wallConnect = try r.bool(); o.wallGap = try r.f64(); o.wallGapHeavy = try r.f64()
        o.wallCross = try r.i32()
        o.crossGap = try r.f64(); o.crossGapHeavy = try r.f64(); o.crossClimbMaxDeg = try r.f64(); o.topRun = try r.f64()
        o.rootRun = try r.f64(); o.runMax = try r.i32()
        o.runGap = try r.f64(); o.runFollow = try r.f64(); o.runPull = try r.f64(); o.runSeek = try r.f64(); o.runMin = try r.f64()
        o.rootGap = try r.f64()
        o.autoByStress = try r.bool(); o.prune = try r.bool(); o.bedFloorMM = try r.f64(); o.holdParts = try r.bool()
        o.partReachMM = try r.f64()
        o.partSupportMM = try r.f64(); o.partToFloor = try r.bool(); o.linkWidth = try r.f64(); o.unbracedMax = try r.f64()
        o.tieLevel = try r.bool()
        o.tieGap = try r.f64(); o.tieGapHeavy = try r.f64(); o.followStress = try r.bool(); o.layerMM = try r.f64()
        o.seed = try r.u64(); o.gapLines = try r.f64()
        o.faceReliefMM = try r.f64(); o.reliefExcludeFaces = try r.pod(Int32.self); o.strandKeep = try r.f64()
        o.wallBareMM = try r.f64(); o.wallReach = try r.f64()
        o.sweep = try r.bool()
        return o
    }

    /// The vines, as columns (one plain array per part of a piece), so a big lattice is a few copies, not a value at a time.
    static func putVines(_ v: OrganicVineShape, _ w: inout PreviewBinWriter) {
        let p = v.params
        w.f32(p.blendMM); w.f32(p.maxTurnDeg); w.f32(p.maxPieceMM); w.f32(p.maxOffsetMM); w.f32(p.flatnessMM); w.int(p.maxPieces)
        let n = v.pieces.count
        var f = [Float](); f.reserveCapacity(n * 20)
        var vine = [Int32](); vine.reserveCapacity(n)
        var bits = [UInt8](); bits.reserveCapacity(n * 4)
        var cutOf = [Int32](); cutOf.reserveCapacity(n)
        var cutUnion: [UInt8] = [], cutCount: [Int32] = [], planes: [Float] = []
        func cut(_ c: OrganicVineShape.Cut?) -> Int32 {
            guard let c else { return -1 }
            cutUnion.append(c.union ? 1 : 0); cutCount.append(Int32(c.planes.count))
            for q in c.planes { planes.append(q.x); planes.append(q.y); planes.append(q.z); planes.append(q.w) }
            return Int32(cutUnion.count - 1)
        }
        for x in v.pieces {
            f.append(x.a.x); f.append(x.a.y); f.append(x.a.z); f.append(x.ra)
            f.append(x.b.x); f.append(x.b.y); f.append(x.b.z); f.append(x.rb)
            for s in [x.ta, x.tb, x.va, x.vb] { f.append(s.x); f.append(s.y); f.append(s.z) }
            vine.append(x.vine)
            bits.append(x.flatA ? 1 : 0); bits.append(x.flatB ? 1 : 0); bits.append(x.section); bits.append(0)
            cutOf.append(cut(x.cut))
        }
        var capCutOf = [Int32](); capCutOf.reserveCapacity(v.capCuts.count)
        for c in v.capCuts { capCutOf.append(cut(c)) }
        var jf = [Float](), jn = [Int32](), jp = [Int32]()
        for j in v.joints {
            jf.append(j.centre.x); jf.append(j.centre.y); jf.append(j.centre.z); jf.append(j.radius)
            jn.append(Int32(j.pieces.count)); jp.append(contentsOf: j.pieces)
        }
        var caps = [Float](); caps.reserveCapacity(v.caps.count * 4)
        for c in v.caps { caps.append(c.x); caps.append(c.y); caps.append(c.z); caps.append(c.w) }
        w.int(n); w.pod(f); w.pod(vine); w.pod(bits); w.pod(cutOf)
        w.pod(cutUnion); w.pod(cutCount); w.pod(planes)
        w.pod(jf); w.pod(jn); w.pod(jp)
        w.pod(caps); w.pod(v.capVines); w.pod(v.capDomes.map { $0 ? UInt8(1) : 0 }); w.int(v.pucks); w.pod(capCutOf)
    }

    static func getVines(_ r: inout PreviewBinReader) throws -> OrganicVineShape {
        var v = OrganicVineShape()
        var p = OrganicVineShape.Params()
        p.blendMM = try r.f32(); p.maxTurnDeg = try r.f32(); p.maxPieceMM = try r.f32(); p.maxOffsetMM = try r.f32()
        p.flatnessMM = try r.f32(); p.maxPieces = try r.int()
        v.params = p
        let n = try r.int()
        let f = try r.pod(Float.self), vine = try r.pod(Int32.self), bits = try r.pod(UInt8.self), cutOf = try r.pod(Int32.self)
        let cutUnion = try r.pod(UInt8.self), cutCount = try r.pod(Int32.self), planes = try r.pod(Float.self)
        guard n >= 0, f.count == n * 20, vine.count == n, bits.count == n * 4, cutOf.count == n,
              cutUnion.count == cutCount.count else { throw PreviewBinReader.Bad.form }
        var starts = [Int](repeating: 0, count: cutCount.count)
        var at = 0
        for (i, c) in cutCount.enumerated() { starts[i] = at; at += Int(c) * 4 }
        guard at == planes.count else { throw PreviewBinReader.Bad.form }
        func cut(_ i: Int32) -> OrganicVineShape.Cut? {
            guard i >= 0, Int(i) < cutCount.count else { return nil }
            let s = starts[Int(i)], k = Int(cutCount[Int(i)])
            var q: [SIMD4<Float>] = []; q.reserveCapacity(k)
            for j in 0..<k { q.append(SIMD4(planes[s + 4 * j], planes[s + 4 * j + 1], planes[s + 4 * j + 2], planes[s + 4 * j + 3])) }
            return OrganicVineShape.Cut(planes: q, union: cutUnion[Int(i)] != 0)
        }
        var pieces: [OrganicVineShape.Piece] = []
        pieces.reserveCapacity(n)
        f.withUnsafeBufferPointer { F in
            for i in 0..<n {
                let o = i * 20
                var x = OrganicVineShape.Piece(a: SIMD3(F[o], F[o + 1], F[o + 2]), ra: F[o + 3],
                                               b: SIMD3(F[o + 4], F[o + 5], F[o + 6]), rb: F[o + 7], vine: vine[i])
                x.ta = SIMD3(F[o + 8], F[o + 9], F[o + 10]); x.tb = SIMD3(F[o + 11], F[o + 12], F[o + 13])
                x.va = SIMD3(F[o + 14], F[o + 15], F[o + 16]); x.vb = SIMD3(F[o + 17], F[o + 18], F[o + 19])
                x.flatA = bits[4 * i] != 0; x.flatB = bits[4 * i + 1] != 0; x.section = bits[4 * i + 2]
                x.cut = cut(cutOf[i])
                pieces.append(x)
            }
        }
        v.pieces = pieces
        let jf = try r.pod(Float.self), jn = try r.pod(Int32.self), jp = try r.pod(Int32.self)
        guard jf.count == jn.count * 4, jp.count == jn.reduce(0, { $0 + Int($1) }) else { throw PreviewBinReader.Bad.form }
        var k = 0
        v.joints = jn.enumerated().map { i, c in
            defer { k += Int(c) }
            return OrganicVineShape.Joint(centre: SIMD3(jf[4 * i], jf[4 * i + 1], jf[4 * i + 2]), radius: jf[4 * i + 3],
                                          pieces: Array(jp[k ..< k + Int(c)]))
        }
        let caps = try r.pod(Float.self)
        guard caps.count % 4 == 0 else { throw PreviewBinReader.Bad.form }
        v.caps = stride(from: 0, to: caps.count, by: 4).map { SIMD4(caps[$0], caps[$0 + 1], caps[$0 + 2], caps[$0 + 3]) }
        v.capVines = try r.pod(Int32.self)
        v.capDomes = try r.pod(UInt8.self).map { $0 != 0 }
        v.pucks = try r.int()
        v.capCuts = try r.pod(Int32.self).map { cut($0) }
        return v
    }
}
