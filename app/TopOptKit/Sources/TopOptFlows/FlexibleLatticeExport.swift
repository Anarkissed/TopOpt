// FlexibleLatticeExport — the Flexible lattice as a binary STL (task
// 2026-09-29-flexible-screens, exporter round). The mesher is flexible_lattice.cpp
// (FlexibleLattice.hpp); this file hands it the grids and drives it.
//
// ★ THE FILE IS THE PREVIEW'S FIELD. There is no core for Flexibles yet (maintainer,
// 2026-09-29), so the exported solid is `FlexibleLatticeField.solid(at:)` evaluated by
// the C++ port — the same function, held to the Swift definition by
// FlexibleLatticeExportTests — and marched at h = t/2.5 (`defaultPitch`).
//
// ★ STREAMED, SLAB BY SLAB, FROM HERE. The C++ side keeps two sample layers and writes
// triangles straight to the file (03-generators §7: flat RSS, like the octet writer);
// Swift calls one step at a time so the caller can show progress and cancel between
// steps. A cancelled or failed export deletes its partial file — a half-written STL
// with a zero triangle count must never be left where a slicer could open it.
//
// ★ ONE COPY EACH WAY ACROSS THE INTEROP. Every grid goes to C++ through
// `flex_floats_from` (one memcpy) and every result comes back through `Array(...)`
// once: reading a C++ vector member element by element from Swift copies the WHOLE
// vector on each read (measured 2026-09-29).

import Foundation
import simd
import TopOptBridge
import TopOptKit

public enum FlexibleLatticeExport {

    /// The export pitch: 2.5 samples across the wall t, the most a thin sheet needs to
    /// come out closed and within the volume the field defines (the box test: < 1 %).
    public static func defaultPitch(wallMM: Double) -> Double { wallMM / 2.5 }

    // MARK: - the grids

    /// `FlexibleLatticeInputs` as the C++ side's POD.
    public static func grids(_ inputs: FlexibleLatticeInputs) -> topoptbridge.FlexLatticeGrids {
        var g = topoptbridge.FlexLatticeGrids()
        g.topology = inputs.topology.rawValue
        g.wall_mm = inputs.wallMM
        g.l_min_mm = inputs.lMinMM
        g.l_max_mm = inputs.lMaxMM
        g.honeycomb_cell_mm = inputs.honeycombCellMM
        g.build_dir = (inputs.buildDir.x, inputs.buildDir.y, inputs.buildDir.z)
        g.skin_mm = inputs.skinMM
        g.rho = grid(inputs.rho)
        g.mask = grid(inputs.mask)
        g.part_sdf = grid(inputs.partSDF)
        g.skin_dist = grid(inputs.skinDist)
        g.bounds_min = (inputs.boundsMin.x, inputs.boundsMin.y, inputs.boundsMin.z)
        g.bounds_max = (inputs.boundsMax.x, inputs.boundsMax.y, inputs.boundsMax.z)
        return g
    }

    static func grid(_ g: FlexGrid) -> topoptbridge.FlexScalarGrid {
        var o = topoptbridge.FlexScalarGrid()
        o.nx = Int32(g.nx); o.ny = Int32(g.ny); o.nz = Int32(g.nz)
        o.c0 = (g.c0.x, g.c0.y, g.c0.z)
        o.spacing = g.spacing
        o.values = floats(g.values)
        return o
    }

    static func floats(_ v: [Float]) -> topoptbridge.FlexFloats {
        v.withUnsafeBufferPointer { topoptbridge.flex_floats_from($0.baseAddress, $0.count) }
    }

    static func validate(_ g: topoptbridge.FlexLatticeGrids) throws {
        let bad = String(topoptbridge.flexible_lattice_grids_error(g))
        if !bad.isEmpty { throw TopOptError(message: "The lattice cannot be exported: \(bad).") }
    }

    // MARK: - the field, through the C++ copy (the agreement test's side)

    public enum Field: Int32, Sendable {
        case lattice = 0   // what the preview draws
        case solid = 1     // what the export writes
    }

    /// The C++ port's field at `points`. Empty when the inputs cannot be evaluated.
    public static func values(_ inputs: FlexibleLatticeInputs, at points: [SIMD3<Float>],
                              field: Field) -> [Float] {
        var xyz = [Float]()
        xyz.reserveCapacity(points.count * 3)
        for p in points { xyz += [p.x, p.y, p.z] }
        return Array(topoptbridge.flexible_lattice_field_values(grids(inputs), floats(xyz), field.rawValue))
    }

    // MARK: - estimate

    /// What an export at `hMM` would cost, before running it (a quasi-random probe of the
    /// cubes; exact on a small grid, ~1 % on the test box).
    public struct Estimate: Equatable, Sendable {
        public let nx: Int, ny: Int, nz: Int
        public let samples: Int
        public let cubes: Int
        public let probedCubes: Int
        /// The share of probed cubes the surface crosses.
        public let crossingFraction: Double
        public let triangles: Int
        public let bytes: Int
    }

    public static func estimate(_ inputs: FlexibleLatticeInputs, hMM: Double) throws -> Estimate {
        let g = grids(inputs)
        try validate(g)
        guard hMM > 0, hMM.isFinite else { throw TopOptError(message: "The export pitch must be > 0 mm.") }
        let e = topoptbridge.flexible_lattice_export_estimate(g, hMM)
        guard e.samples > 0 else {
            throw TopOptError(message: "A pitch of \(hMM) mm is too fine for this part to export.")
        }
        return Estimate(nx: Int(e.nx), ny: Int(e.ny), nz: Int(e.nz), samples: Int(e.samples), cubes: Int(e.cubes),
                        probedCubes: Int(e.probed_cubes), crossingFraction: e.crossing_fraction,
                        triangles: Int(e.triangles), bytes: Int(e.bytes))
    }

    // MARK: - export

    /// Where an export stands, and the sample storage it holds (two layers, never the grid).
    public struct Status: Equatable, Sendable {
        public let nx: Int, ny: Int, nz: Int
        public let slabsTotal: Int
        public let slabsDone: Int
        public let triangles: Int
        /// One sample layer: nx · ny floats.
        public let slabFloats: Int
        public let sampleFloatsAllocated: Int
        /// The most sample storage the export has held so far.
        public let sampleFloatsPeak: Int
        public let writeBufferBytes: Int
    }

    /// One export in flight: `step` until 0 slabs are left, then `finish`. Released
    /// without `finish`, it cancels — the partial file is deleted.
    public final class Session {
        public let url: URL
        private var handle: Int64

        public convenience init(_ inputs: FlexibleLatticeInputs, hMM: Double, to url: URL) throws {
            try self.init(grids: FlexibleLatticeExport.grids(inputs), hMM: hMM, to: url)
        }

        init(grids g: topoptbridge.FlexLatticeGrids, hMM: Double, to url: URL) throws {
            try FlexibleLatticeExport.validate(g)
            self.url = url
            var err = topoptbridge.BridgeError()
            handle = topoptbridge.flexible_lattice_export_begin(g, hMM, std.string(url.path), &err)
            if !err.ok || handle == 0 {
                handle = 0
                throw TopOptError(message: String(err.message))
            }
        }

        deinit { cancel() }

        /// March up to `slabs` more z-slabs; returns the slabs left (0 = all marched).
        public func step(slabs: Int) throws -> Int {
            var err = topoptbridge.BridgeError()
            let left = topoptbridge.flexible_lattice_export_step(handle, Int32(clamping: slabs), &err)
            if !err.ok || left < 0 { throw TopOptError(message: String(err.message)) }
            return Int(left)
        }

        public func status() throws -> Status {
            var err = topoptbridge.BridgeError()
            let s = topoptbridge.flexible_lattice_export_status(handle, &err)
            if !err.ok { throw TopOptError(message: String(err.message)) }
            return Status(nx: Int(s.nx), ny: Int(s.ny), nz: Int(s.nz), slabsTotal: Int(s.slabs_total),
                          slabsDone: Int(s.slabs_done), triangles: Int(s.triangles),
                          slabFloats: Int(s.slab_floats), sampleFloatsAllocated: Int(s.sample_floats_allocated),
                          sampleFloatsPeak: Int(s.sample_floats_peak), writeBufferBytes: Int(s.write_buffer_bytes))
        }

        /// Marches whatever is left, patches the triangle count and closes the file.
        public func finish() throws -> (triangles: Int, bytes: Int) {
            var err = topoptbridge.BridgeError()
            let r = topoptbridge.flexible_lattice_export_finish(handle, &err)
            handle = 0   // released either way; a failed finish has deleted its file
            if !err.ok { throw TopOptError(message: String(err.message)) }
            return (Int(r.triangles), Int(r.bytes))
        }

        /// Stops and deletes the partial file. Safe to call twice.
        public func cancel() {
            guard handle != 0 else { return }
            topoptbridge.flexible_lattice_export_cancel(handle)
            handle = 0
        }
    }

    /// At most ~1 % of the slabs and at most about a million samples a step, so the bar
    /// moves in small steps and a cancel lands within a frame or two of work. ★ Samples
    /// alone were not enough: the test box's 40 slabs fit in ONE million-sample step,
    /// so progress jumped 0 → 1 and a cancel could never land mid-export. A step
    /// call costs microseconds; a slab of samples costs a millisecond or more.
    static func slabsPerStep(slabFloats: Int, slabsTotal: Int) -> Int {
        let bySamples = 1_000_000 / Swift.max(1, slabFloats)
        let byShare = (slabsTotal + 99) / 100
        return Swift.max(1, Swift.min(bySamples, byShare))
    }

    /// Write the lattice's solid (`FlexibleLatticeField.solid`) at pitch `hMM` to `url`
    /// as binary STL. Runs on the calling thread — call it off the main actor.
    /// `progress` gets the fraction of slabs marched (0 first, 1 last) and returns false
    /// to cancel: the partial file is deleted and `CancellationError` is thrown.
    @discardableResult
    public static func export(_ inputs: FlexibleLatticeInputs, hMM: Double, to url: URL,
                              progress: (Double) -> Bool) throws -> (triangles: Int, bytes: Int) {
        let session = try Session(inputs, hMM: hMM, to: url)
        let start = try session.status()
        let total = Swift.max(1, start.slabsTotal)
        let per = slabsPerStep(slabFloats: start.slabFloats, slabsTotal: start.slabsTotal)
        guard progress(0) else { session.cancel(); throw CancellationError() }
        var left = start.slabsTotal
        while left > 0 {
            do {
                left = try session.step(slabs: per)
            } catch {
                session.cancel()
                throw error
            }
            guard progress(Double(total - left) / Double(total)) else {
                session.cancel()
                throw CancellationError()
            }
        }
        return try session.finish()
    }
}
