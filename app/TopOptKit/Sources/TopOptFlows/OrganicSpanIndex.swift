import Foundation
import simd

/// ★★★ THE EMITTED SPANS OF AN ORGANIC RUN, INDEXED FOR THE PREVIEW (2026-09-02).
///
/// Reads the span file core writes under `lattice.emit_organic_spans` — one `SEG`
/// per strut ACTUALLY EMITTED, post-prune, from the same ledger the weld reads — and
/// builds a uniform grid over it so a raymarch can ask "which capsules are near p"
/// with a handful of tests per sample. This is the field the octet path cannot
/// provide: domain repetition folds the world into ONE cell and an organic lattice
/// has no cell to fold into, so its distance is the min over ACTUAL nearby capsules.
///
/// ★ SIZED ONCE, NOT PER FRAME. On the M2 (195 x 54 x 195 mm, ~106k segments) a 4 mm
/// grid is ~49 x 14 x 49 = 34k cells and ~300k references — a few MB. The index has the
/// lifetime of the run's data, exactly like the octet bake: rebuilt on a run change,
/// never while orbiting.
///
/// ★ IT CARRIES ITS OWN RECEIPT. `count` and `totalLengthMM` are what was INDEXED, so a
/// caller can hold them against the run's own `span_count` / `span_length_mm` and
/// FAIL LOUDLY if the preview would draw a different object from the one certified
/// (§10 of the task). Never write zero spans silently: an empty file is an error here
/// too, mirroring core's refusal to write one.
public struct OrganicSpanIndex: Sendable {

    public struct Segment: Sendable, Equatable {
        public var a: SIMD3<Float>
        public var b: SIMD3<Float>
        public var r: Float
    }

    public enum ReadError: Error, Equatable {
        case unreadable(String)
        case noGridHeader
        case noSpans
        case malformedLine(Int)
    }

    /// The design grid the run was baked on — the `GRID` header, verbatim.
    public let gridOrigin: SIMD3<Float>
    public let gridSpacing: Float
    public let gridDims: SIMD3<Int32>
    /// Every emitted strut, in file order.
    public let segments: [Segment]
    /// What was indexed — the numbers to hold against the run's receipt.
    public var count: Int { segments.count }
    public let totalLengthMM: Double

    // The uniform index: cell -> a range into `references`.
    public let cellMM: Float
    public let indexOrigin: SIMD3<Float>
    public let indexDims: SIMD3<Int32>
    /// `cellStart[c] ..< cellStart[c + 1]` indexes `references` for cell `c`.
    public let cellStart: [Int32]
    public let references: [Int32]

    // MARK: - reading

    public static func read(path: String, cellMM: Float = 4) throws -> OrganicSpanIndex {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ReadError.unreadable(path)
        }
        return try parse(text, cellMM: cellMM)
    }

    public static func parse(_ text: String, cellMM: Float = 4) throws -> OrganicSpanIndex {
        var origin = SIMD3<Float>(0, 0, 0), spacing: Float = 0, dims = SIMD3<Int32>(0, 0, 0)
        var haveGrid = false
        var segs: [Segment] = []
        var lineNo = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            let f = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard let tag = f.first else { continue }
            switch tag {
            case "GRID":
                guard f.count == 8, let ox = Float(f[1]), let oy = Float(f[2]), let oz = Float(f[3]),
                      let h = Float(f[4]), let nx = Int32(f[5]), let ny = Int32(f[6]),
                      let nz = Int32(f[7]) else { throw ReadError.malformedLine(lineNo) }
                origin = SIMD3(ox, oy, oz); spacing = h; dims = SIMD3(nx, ny, nz); haveGrid = true
            case "SEG":
                guard f.count == 8, let ax = Float(f[1]), let ay = Float(f[2]), let az = Float(f[3]),
                      let bx = Float(f[4]), let by = Float(f[5]), let bz = Float(f[6]),
                      let r = Float(f[7]) else { throw ReadError.malformedLine(lineNo) }
                segs.append(Segment(a: SIMD3(ax, ay, az), b: SIMD3(bx, by, bz), r: r))
            default:
                continue          // SKIN / BC / LOAD and anything else: not ours
            }
        }
        guard haveGrid else { throw ReadError.noGridHeader }
        guard !segs.isEmpty else { throw ReadError.noSpans }
        return OrganicSpanIndex(gridOrigin: origin, gridSpacing: spacing, gridDims: dims,
                                segments: segs, cellMM: cellMM)
    }

    // MARK: - building the index

    public init(gridOrigin: SIMD3<Float>, gridSpacing: Float, gridDims: SIMD3<Int32>,
                segments: [Segment], cellMM: Float = 4) {
        self.gridOrigin = gridOrigin; self.gridSpacing = gridSpacing; self.gridDims = gridDims
        self.segments = segments
        self.cellMM = max(cellMM, 0.1)
        var total = 0.0
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for s in segments {
            total += Double(simd_length(s.b - s.a))
            let rr = SIMD3<Float>(repeating: s.r)
            lo = simd_min(lo, simd_min(s.a, s.b) - rr)
            hi = simd_max(hi, simd_max(s.a, s.b) + rr)
        }
        self.totalLengthMM = total
        // ★ THE INDEX COVERS THE CAPSULES, NOT THE DESIGN GRID — a strut's radius
        // reaches past its endpoints, and a query one radius outside the last node
        // must still find it.
        let c = self.cellMM
        let o = segments.isEmpty ? SIMD3<Float>(0, 0, 0) : lo - SIMD3<Float>(repeating: c)
        let extent = segments.isEmpty ? SIMD3<Float>(0, 0, 0) : (hi - o) + SIMD3<Float>(repeating: c)
        let dims = SIMD3<Int32>(Int32(max(1, ceil(extent.x / c))), Int32(max(1, ceil(extent.y / c))),
                                Int32(max(1, ceil(extent.z / c))))
        self.indexOrigin = o; self.indexDims = dims
        let ncell = Int(dims.x) * Int(dims.y) * Int(dims.z)
        // Two passes: count per cell, then fill — one contiguous reference array.
        var counts = [Int32](repeating: 0, count: ncell)
        func cellRange(_ s: Segment) -> (SIMD3<Int>, SIMD3<Int>) {
            let rr = SIMD3<Float>(repeating: s.r)
            let mn = (simd_min(s.a, s.b) - rr - o) / c
            let mx = (simd_max(s.a, s.b) + rr - o) / c
            let i0 = SIMD3<Int>(max(0, Int(floor(mn.x))), max(0, Int(floor(mn.y))), max(0, Int(floor(mn.z))))
            let i1 = SIMD3<Int>(min(Int(dims.x) - 1, Int(floor(mx.x))), min(Int(dims.y) - 1, Int(floor(mx.y))),
                                min(Int(dims.z) - 1, Int(floor(mx.z))))
            return (i0, i1)
        }
        @inline(__always) func cid(_ x: Int, _ y: Int, _ z: Int) -> Int {
            x + Int(dims.x) * (y + Int(dims.y) * z)
        }
        for s in segments {
            let (i0, i1) = cellRange(s)
            for z in i0.z...i1.z { for y in i0.y...i1.y { for x in i0.x...i1.x { counts[cid(x, y, z)] += 1 } } }
        }
        var start = [Int32](repeating: 0, count: ncell + 1)
        for i in 0..<ncell { start[i + 1] = start[i] + counts[i] }
        var refs = [Int32](repeating: 0, count: Int(start[ncell]))
        var fill = start
        for (si, s) in segments.enumerated() {
            let (i0, i1) = cellRange(s)
            for z in i0.z...i1.z { for y in i0.y...i1.y { for x in i0.x...i1.x {
                let k = cid(x, y, z); refs[Int(fill[k])] = Int32(si); fill[k] += 1
            } } }
        }
        self.cellStart = start; self.references = refs
    }

    // MARK: - queries (the CPU twin of the shader's distance)

    /// Indices of the segments whose capsule bounds touch the cell containing `p`.
    public func candidates(near p: SIMD3<Float>) -> ArraySlice<Int32> {
        let g = (p - indexOrigin) / cellMM
        let x = Int(floor(g.x)), y = Int(floor(g.y)), z = Int(floor(g.z))
        guard x >= 0, y >= 0, z >= 0, x < Int(indexDims.x), y < Int(indexDims.y), z < Int(indexDims.z)
        else { return [] }
        let k = x + Int(indexDims.x) * (y + Int(indexDims.y) * z)
        return references[Int(cellStart[k])..<Int(cellStart[k + 1])]
    }

    /// Signed distance to the union of nearby capsules — negative inside a strut.
    /// `+inf` when no capsule is indexed near `p`.
    public func distance(_ p: SIMD3<Float>) -> Float {
        var best = Float.infinity
        for i in candidates(near: p) {
            let s = segments[Int(i)]
            let ab = s.b - s.a, ap = p - s.a
            let denom = simd_dot(ab, ab)
            let t = denom > 0 ? max(0, min(1, simd_dot(ap, ab) / denom)) : 0
            best = min(best, simd_length(p - (s.a + ab * t)) - s.r)
        }
        return best
    }
}

// MARK: - baking the field the march already knows how to draw

extension OrganicSpanIndex {
    /// ★★★ THE CAPSULE-MIN FIELD, BAKED ONTO THE MARCH'S OWN GRID.
    ///
    /// The unified march already has an organic branch: it samples `organicTex` — a
    /// voxel field of signed distance to the struts — and unions it with the part clip.
    /// Until now that field could only come from a preview-time trace. This bakes the
    /// SAME kind of field from the run's EMITTED spans, so the picture is the object
    /// that was certified, with no shader change: same raymarch, same masking, only
    /// where the distance comes from.
    ///
    /// ★ RESOLUTION IS THE TRADE, AND IT IS SAID. A 1.7 mm voxel cannot resolve a
    /// 0.6 mm strut crisply — the distance is exact AT the voxel centres and linear
    /// between them. The in-shader capsule-min (the task's Step 3) is the fidelity
    /// upgrade; this is the end-to-end, cross-checkable path that lands first.
    ///
    /// Values are clamped to `+bandMM` outside any capsule, which is what the march's
    /// `organicSpacing.w` ("outside the field, the clamped band") expects.
    public func bakeField(origin: SIMD3<Float>, spacing: SIMD3<Float>,
                          dims: SIMD3<Int>, bandMM: Float) -> LatticeVoxelGrid {
        let nx = max(1, dims.x), ny = max(1, dims.y), nz = max(1, dims.z)
        var values = [Float](repeating: bandMM, count: nx * ny * nz)
        // ★ ONLY VOXELS NEAR A CAPSULE ARE VISITED. Walking every voxel and asking the
        // index is O(voxels); walking every segment's own footprint is O(struts × local
        // voxels), which is far smaller on a sparse lattice and touches nothing far
        // from the material — those voxels simply keep the band.
        let inv = SIMD3<Float>(1 / spacing.x, 1 / spacing.y, 1 / spacing.z)
        for s in segments {
            let reach = s.r + bandMM
            let rr = SIMD3<Float>(repeating: reach)
            let mn = (simd_min(s.a, s.b) - rr - origin) * inv
            let mx = (simd_max(s.a, s.b) + rr - origin) * inv
            let i0 = SIMD3<Int>(max(0, Int(floor(mn.x))), max(0, Int(floor(mn.y))), max(0, Int(floor(mn.z))))
            let i1 = SIMD3<Int>(min(nx - 1, Int(ceil(mx.x))), min(ny - 1, Int(ceil(mx.y))),
                                min(nz - 1, Int(ceil(mx.z))))
            guard i0.x <= i1.x, i0.y <= i1.y, i0.z <= i1.z else { continue }
            let ab = s.b - s.a
            let denom = simd_dot(ab, ab)
            for z in i0.z...i1.z {
                let pz = origin.z + Float(z) * spacing.z
                for y in i0.y...i1.y {
                    let py = origin.y + Float(y) * spacing.y
                    var k = i0.x + nx * (y + ny * z)
                    for x in i0.x...i1.x {
                        let p = SIMD3<Float>(origin.x + Float(x) * spacing.x, py, pz)
                        let t = denom > 0 ? max(0, min(1, simd_dot(p - s.a, ab) / denom)) : 0
                        let d = simd_length(p - (s.a + ab * t)) - s.r
                        if d < values[k] { values[k] = d }
                        k += 1
                    }
                }
            }
        }
        return LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing,
                                values: values)
    }
}
