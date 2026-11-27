// RemoteScenarioFields — decode core's per-scenario fields container, out/scenario_fields.bin (v1, TO-core 2026-10-28,
// core/include/topopt/fields.hpp). A run with two or more load scenarios writes it beside fields.bin; fields.bin stays the
// GOVERNING scenario's. Like fields.bin it is ENRICHMENT: missing, truncated or unknown-version input decodes to nil and
// the Scenario menu simply says which scenario the views show. Every read is bounds-checked.
//
// v1, little-endian:
//   u8 version = 1, u8[3] 0; i32 nx, ny, nz; f64 origin x, y, z, spacing; i32 S; i32 V;
//   S × { i32 byte_count, UTF-8 name }                       (report.json scenarios[] order)
//   V × { f64 requested_volume_fraction; i32 governing; i32 0;
//         S × { i64 vm_count, i64 disp_count, f32[vm_count] von Mises MPa, f32[disp_count] displacement mm } }

import Foundation
import TopOptKit

struct RemoteScenarioFields: Equatable {
    struct Block: Equatable {
        let requestedVF: Double
        let governing: Int
        let sets: [ScenarioFieldSet]
    }

    static let formatVersion: UInt8 = 1

    let gridNx: Int
    let gridNy: Int
    let gridNz: Int
    let names: [String]
    let blocks: [Block]

    /// The block for a variant's ladder rung (the same join key fields.bin uses), or nil.
    func sets(forRequestedVF vf: Double, tolerance: Double = 1e-4) -> [ScenarioFieldSet] {
        var best: Block?, bestErr = tolerance
        for b in blocks { let e = abs(b.requestedVF - vf); if e < bestErr { bestErr = e; best = b } }
        return best?.sets ?? []
    }

    static func parse(_ data: Data) -> RemoteScenarioFields? {
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
        func f32Array(_ count: Int64) -> [Float]? {
            guard count >= 0, count <= Int64((bytes.count - cur) / 4) else { return nil }
            var out = [Float](); out.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                var bits: UInt32 = 0
                for i in 0..<4 { bits |= UInt32(bytes[cur + i]) << (8 * i) }
                cur += 4
                out.append(Float(bitPattern: bits))
            }
            return out
        }

        guard let version = u8(), version == formatVersion, skip(3) else { return nil }
        guard let nx = i32(), let ny = i32(), let nz = i32(), nx > 0, ny > 0, nz > 0 else { return nil }
        guard f64() != nil, f64() != nil, f64() != nil, f64() != nil else { return nil }   // origin + spacing (== fields.bin's)
        guard let sCount = i32(), let vCount = i32(), sCount >= 2, sCount < 1_000, vCount >= 0, vCount < 100_000
        else { return nil }
        var names: [String] = []
        for _ in 0..<Int(sCount) {
            guard let n = i32(), n >= 0, need(Int(n)),
                  let name = String(bytes: bytes[cur..<(cur + Int(n))], encoding: .utf8) else { return nil }
            cur += Int(n)
            names.append(name)
        }
        let voxels = Int64(nx) * Int64(ny) * Int64(nz)
        let dofs = 3 * Int64(nx + 1) * Int64(ny + 1) * Int64(nz + 1)
        var blocks: [Block] = []
        for _ in 0..<Int(vCount) {
            guard let vf = f64(), let gov = i32(), gov >= 0, gov < sCount, skip(4) else { return nil }
            var sets: [ScenarioFieldSet] = []
            for k in 0..<Int(sCount) {
                guard let vmN = i64(), let dispN = i64(), vmN == voxels, dispN == dofs,
                      let vm = f32Array(vmN), let disp = f32Array(dispN) else { return nil }
                sets.append(ScenarioFieldSet(name: names[k], vonMises: vm, displacement: disp))
            }
            blocks.append(Block(requestedVF: vf, governing: Int(gov), sets: sets))
        }
        return RemoteScenarioFields(gridNx: Int(nx), gridNy: Int(ny), gridNz: Int(nz), names: names, blocks: blocks)
    }
}
