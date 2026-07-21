// RemoteFields — decode the per-voxel result FIELDS container a LAN worker serves
// (handoff 122). The CLI writes out/fields.bin after a run; RemoteRunner fetches it
// so a remote run's results screen lights up the SAME overlays a local run does
// (stress / flex / load-path) and shows the voxel mass, instead of "n/a — computed
// on Mac". This is the Swift mirror of core/include/topopt/fields.hpp (v1) — the
// two MUST stay in lock-step; the C++ round-trip test (test_fields.cpp) and the
// Swift parser test (RemoteFieldsTests) pin the same byte layout from both ends.
//
// Robustness: fields are ENRICHMENT, never load-bearing for correctness. A missing,
// truncated, or unknown-version container decodes to `nil` and the caller simply
// leaves the overlays gated (the "computed on Mac" note stays) — a bad fields.bin
// must never crash the app or corrupt a result. Every read is bounds-checked.

import Foundation

/// A decoded `fields.bin` (handoff 122). Little-endian throughout; see
/// `topopt/fields.hpp` for the on-disk layout.
struct RemoteFieldsContainer: Equatable {
    /// One accepted variant's fields, keyed to its ladder rung (`requestedVF`).
    struct Variant: Equatable {
        let requestedVF: Double
        let massGrams: Double
        let supportVolumeVoxels: Int
        /// Per-voxel von Mises (MPa), grid-indexed to the container's grid.
        let vonMises: [Float]
        /// Per-voxel Cauchy tensor (Voigt, 6·voxelCount). Empty in v1 (see hpp).
        let stressTensor: [Float]
        /// Per-node displacement (mm), DOF-ordered (3·nodeCount).
        let displacement: [Float]
    }

    /// The version byte the parser accepts. A container that opens with any other
    /// value decodes to nil (forward/backward incompatible → don't misparse).
    static let formatVersion: UInt8 = 1

    let gridNx: Int
    let gridNy: Int
    let gridNz: Int
    let gridOrigin: SIMD3<Double>
    let spacing: Double
    let voxelVolumeMM3: Double
    let variants: [Variant]

    /// The block whose ladder rung matches `vf` (a streamed variant's requested
    /// volume fraction — the same join key the mesh/report assembly uses). Returns
    /// nil if none is within tolerance, so a variant with no matching fields simply
    /// stays un-enriched rather than grabbing the nearest block.
    func variant(forRequestedVF vf: Double, tolerance: Double = 1e-4) -> Variant? {
        var best: Variant?
        var bestErr = tolerance
        for v in variants {
            let e = abs(v.requestedVF - vf)
            if e < bestErr { bestErr = e; best = v }
        }
        return best
    }

    /// Parse a `fields.bin` body. Returns nil on any malformed / unknown-version /
    /// truncated input (never throws — the caller degrades gracefully).
    static func parse(_ data: Data) -> RemoteFieldsContainer? {
        let bytes = [UInt8](data)
        var cur = 0

        func need(_ n: Int) -> Bool { n >= 0 && n <= bytes.count - cur }
        func u8() -> UInt8? { guard need(1) else { return nil }; defer { cur += 1 }; return bytes[cur] }
        func skip(_ n: Int) -> Bool { guard need(n) else { return false }; cur += n; return true }
        func u32() -> UInt32? {
            guard need(4) else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[cur + i]) << (8 * i) }
            cur += 4
            return v
        }
        func u64() -> UInt64? {
            guard need(8) else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[cur + i]) << (8 * UInt64(i)) }
            cur += 8
            return v
        }
        func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
        func i64() -> Int64? { u64().map { Int64(bitPattern: $0) } }
        func f64() -> Double? { u64().map { Double(bitPattern: $0) } }
        func f32Array(_ count: Int) -> [Float]? {
            // Bound the count by the bytes actually remaining (no multiply overflow).
            guard count >= 0, count <= (bytes.count - cur) / 4 else { return nil }
            var out = [Float]()
            out.reserveCapacity(count)
            for _ in 0..<count {
                var bits: UInt32 = 0
                for i in 0..<4 { bits |= UInt32(bytes[cur + i]) << (8 * i) }
                cur += 4
                out.append(Float(bitPattern: bits))
            }
            return out
        }

        // -- run header --
        guard let version = u8(), version == formatVersion else { return nil }
        guard skip(3) else { return nil }                       // reserved
        guard let nx = i32(), let ny = i32(), let nz = i32() else { return nil }
        guard let ox = f64(), let oy = f64(), let oz = f64() else { return nil }
        guard let sp = f64(), let vv = f64() else { return nil }
        guard let vcount = i32(), vcount >= 0, vcount < 100_000 else { return nil }
        guard skip(4) else { return nil }                       // reserved

        // -- variant blocks --
        var variants: [Variant] = []
        variants.reserveCapacity(Int(vcount))
        for _ in 0..<Int(vcount) {
            guard let vf = f64(), let mass = f64(), let support = i32() else { return nil }
            guard skip(4) else { return nil }                   // reserved
            guard let vmN = i64(), let stN = i64(), let dispN = i64() else { return nil }
            guard vmN >= 0, stN >= 0, dispN >= 0 else { return nil }
            guard let vm = f32Array(Int(vmN)),
                  let st = f32Array(Int(stN)),
                  let disp = f32Array(Int(dispN)) else { return nil }
            variants.append(Variant(requestedVF: vf, massGrams: mass,
                                    supportVolumeVoxels: Int(support),
                                    vonMises: vm, stressTensor: st, displacement: disp))
        }
        return RemoteFieldsContainer(
            gridNx: Int(nx), gridNy: Int(ny), gridNz: Int(nz),
            gridOrigin: SIMD3<Double>(ox, oy, oz), spacing: sp,
            voxelVolumeMM3: vv, variants: variants)
    }
}
