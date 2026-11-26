// LatticeSessionStrutTap — ★ notes30 (his 11-26, option D): the layout session's strut tap as the page reads it: core's StrutTap
// through the bridge (D-core, claude/notes30-stream-core: lattice_layout_strut_read / lattice_layout_strut_map, api.md),
// turned into what the timelapse rises by (LatticeStrutRead):
//   * the plan (the up, the box) as core fixed it at the lay's start;
//   * THE LINE the floors wait for: core's `line_mm` says the cells below it are laid and settled, but a strut is handed over
//     only once its certificate holds (its width final, the drop unable to peel it, its piece held), so a floor is taken as
//     handed over once BOTH core's line is a strut's reach past it and the struts already handed reach above it: the line
//     here is the lower of core's line less a reach and the highest top handed over so far (+∞ once the lay has landed); a
//     strut's reach is the most any handed over rises. A strut that still comes for a floor already standing is held back
//     for the cladding (LatticeStrutStream.holdBack): never one popping in, never one taken away;
//   * the map: core makes it in the lay, slab by slab behind its line (`map_slabs_done`); the slabs newly final are copied
//     from lattice_layout_strut_map, and the map's line is the lowest height of a slab not final yet.
// Synchronous, any thread, never through the session's worker (the lay occupies it): as growthRead.
import Foundation
import simd
import TopOptKit

final class LatticeSessionStrutTap: LatticeStrutTap {
    private weak var session: LatticeLayoutSession?
    private var map: (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>)?
    private var lay: UInt64 = 0
    private var slabsTaken: [Bool] = []
    private var top: Float = -.infinity
    private var reach: Float = 0
    /// The rows handed out so far (the read's `mapNext`).
    private var rowsHanded = 0

    init(_ session: LatticeLayoutSession) { self.session = session }

    func streamNextLay(up: SIMD3<Float>, map: (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>)?) {
        self.map = map
        session?.streamNextLay(.init(up: SIMD3<Double>(up), mapOrigin: map?.origin ?? .zero, mapVoxel: map?.voxel ?? 0,
                                     mapDims: map?.dims ?? .zero))
    }

    func strutRead(from: Int, most: Int, mapFrom: Int) throws -> LatticeStrutRead {
        guard let session else { throw CancellationError() }
        let s = try session.strutRead(from: from, most: most)
        if s.lay != lay { lay = s.lay; slabsTaken = []; top = -.infinity; reach = 0; rowsHanded = 0 }
        let up = simd_length(s.up) > 1e-6 ? simd_normalize(s.up) : SIMD3<Float>(0, 0, 1)
        let n = Swift.min(s.bars.count / 7, s.flags.count)
        for i in 0..<n {
            let k = 7 * i
            let ha = simd_dot(up, SIMD3(s.bars[k], s.bars[k + 1], s.bars[k + 2]))
            let hb = simd_dot(up, SIMD3(s.bars[k + 3], s.bars[k + 4], s.bars[k + 5]))
            top = Swift.max(top, Swift.max(ha, hb)); reach = Swift.max(reach, abs(ha - hb))
        }
        let landed = s.phase >= 4
        var r = LatticeStrutRead(lay: s.lay, phase: s.phase, next: s.next,
                                 up: s.slots > 0 || s.phase >= 1 ? up : nil, lo: s.lo, hi: s.hi,
                                 slotsDone: s.slotsLaid, slotsTotal: s.slots,
                                 line: landed ? .infinity : Swift.min(top, Float(Swift.max(s.lineMM, -1e30)) - reach), reach: reach,
                                 bars: Array(s.bars[0..<(7 * n)]), flags: Array(s.flags[0..<n]))
        if let m = map, s.mapState >= 1 { takeMap(s, m, up: up, into: &r, session: session) }
        r.mapNext = rowsHanded
        return r
    }

    /// The map's slabs newly final, copied from the stream's map; the map's line below the lowest slab not final yet.
    private func takeMap(_ s: LatticeLayoutSession.Struts, _ m: (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>),
                         up: SIMD3<Float>, into r: inout LatticeStrutRead, session: LatticeLayoutSession) {
        let nx = Int(m.dims.x), ny = Int(m.dims.y), nz = Int(m.dims.z), slab = 2 * nx * ny
        if slabsTaken.count != nz { slabsTaken = Array(repeating: false, count: nz) }
        let done: [Bool] = s.mapSlabsDone.count == nz ? s.mapSlabsDone.map { $0 != 0 } : Array(repeating: s.mapState >= 1, count: nz)
        let fresh = (0..<nz).filter { done[$0] && !slabsTaken[$0] }
        if !fresh.isEmpty, let rg = try? session.strutMap(), rg.count == slab * nz {
            var z = 0
            while z < fresh.count {   // contiguous runs, one piece each
                var e = z
                while e + 1 < fresh.count, fresh[e + 1] == fresh[e] + 1 { e += 1 }
                let z0 = fresh[z], z1 = fresh[e] + 1
                r.mapRows.append(.init(z0: Int32(z0), z1: Int32(z1), rg: Array(rg[(z0 * slab)..<(z1 * slab)])))
                for k in z0..<z1 { slabsTaken[k] = true }
                rowsHanded += z1 - z0
                z = e + 1
            }
        }
        // the map's line: below the lowest point (along up) of any slab not final yet; +∞ when every one is
        var line = Float.infinity
        for k in 0..<nz where !slabsTaken[k] {
            var lowest = Float.greatestFiniteMagnitude
            for c in 0..<4 {
                let p = m.origin + m.voxel * SIMD3(Float(c & 1 == 0 ? 0 : nx - 1), Float(c & 2 == 0 ? 0 : ny - 1), Float(k))
                lowest = Swift.min(lowest, simd_dot(up, p))
            }
            line = Swift.min(line, lowest - m.voxel)
        }
        r.mapLine = line
    }
}
