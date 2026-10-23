// StepMeshRepair — closes a STEP import that OCCT tessellated with cracks, keeping
// every CAD face id (round 8; his squish-rig parts, 2026-10-23: four valid STEP
// solids refused as "not watertight" while Fusion's Validate finds nothing).
//
// ★ ROOT CAUSE, MEASURED (his 7 rig parts; OCCT 7.9.3; core/src/io/step.cpp meshes the
// WHOLE shape once — BRepMesh_IncrementalMesh 0.1 mm absolute, 0.5 rad, parallel — so
// shared edges ARE discretised once; it then welds nodes on a 1e-6 mm grid and runs
// check_watertight with no clean-up step in between):
//
//   (1) POLE SLIVERS. A corner where three fillets meet is a sphere octant or a
//       3-sided B-spline patch, and that face carries a DEGENERATED edge (a pole,
//       BRep_Tool::Degenerated). BRepMesh gives the pole two nodes, distinct in UV,
//       at the SAME 3D point. A triangle on both of them welds to (a, a, b): zero
//       area, a self-edge counted once (a "boundary" edge) and an edge counted four
//       times (a "non-manifold" edge). The mesh path's weld_and_clean drops exactly
//       these triangles; the STEP path keeps them. Carriage Arms has 8 (faces 108, 112,
//       114, 118, 120, 134, 139, 155), Pressing Plate Mount 4, Top Motor Mount 10,
//       2040 Extrusion Stand 2. With them gone the first three are closed.
//   (2) ONE BROKEN FACE TRIANGULATION. 2040 Extrusion Stand face 16 is a plane whose
//       outer wire has 0.01–0.05 mm edges. At 0.1 mm BRepMesh returns it with a
//       4-edge hole and overlapping triangles (771.9 mm² of triangles on a 725.2 mm²
//       face), and reports no error. At 0.05 mm the same face meshes correctly.
//
// ★ THE REPAIR runs ONLY when the import of a .step/.stp is NOT watertight (the gate,
// `needsRepair`). Already-watertight imports never reach it, so their meshes stay
// byte-identical. Passes, first accepted wins:
//   T1 drop the pole slivers — triangles whose welded corners repeat. Exactly zero
//      area and zero volume; every other triangle, vertex and face id is untouched.
//   T2 re-tessellate the same file at 1/2, then 1/4, of the linear deflection through
//      the core's own importer (same TopExp face order ⇒ the same face ids), then T1.
// A pass is ACCEPTED only when the mesh is a closed, consistently oriented 2-manifold
// with positive volume, the same face count, and every face id the original carried on
// a triangle with area.
// Nothing accepted ⇒ the original mesh comes back unchanged (refused, as today).
//
// ★ WHAT THIS DOES NOT REACH: core's runs re-read the STEP and tessellate it again at
// 0.1 mm themselves. T1's slivers are harmless there (zero area); T2's broken face is
// not (see the round-8 report). The repaired mesh also has fewer triangles than core's
// (T1) or different ones (T2), so a triangle-indexed face-overrides sidecar painted on
// a repaired part does not index core's mesh the same way. The real fix for both is
// in core's step.cpp, which this branch does not edit.
import Foundation
import TopOptBridge

/// What `StepMeshRepair` did to one import, for tests and logs.
public struct StepMeshRepairReport: Equatable, Sendable {
    public enum Pass: String, Equatable, Sendable {
        /// The gate was closed: not a STEP, or already watertight. Mesh untouched.
        case notNeeded
        /// T1 closed it: zero-area pole slivers dropped from the stock tessellation.
        case poleSlivers
        /// T2 closed it: re-tessellated at `linearDeflectionMM`, then T1.
        case retessellated
        /// Nothing passed; the original (not watertight) mesh came back.
        case gaveUp
    }
    public let pass: Pass
    /// Pole slivers dropped from the mesh that was returned.
    public let droppedSlivers: Int
    /// The re-tessellation rung that closed it (T2 only).
    public let linearDeflectionMM: Double?
    public let stockTriangles: Int
    public let repairedTriangles: Int
}

public enum StepMeshRepair {

    /// core's `StepTessellation::linear_deflection` default (core/include/topopt/step.hpp),
    /// the deflection an import with `linearDeflectionMM <= 0` was meshed at.
    public static let coreDefaultLinearDeflectionMM = 0.1

    /// The T2 ladder, as fractions of the deflection the stock import used.
    public static let retessellationFractions: [Double] = [0.5, 0.25]

    // MARK: - the gate

    /// The extensions core's `part_format_for_path` reads as STEP.
    public static func isStepPath(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix(".step") || p.hasSuffix(".stp")
    }

    /// THE GATE: a STEP whose import is not watertight. Nothing else is touched.
    public static func needsRepair(path: String, mesh: ImportedMesh) -> Bool {
        isStepPath(path) && !mesh.watertight
    }

    // MARK: - the repair

    /// The repaired mesh, or `mesh` itself when nothing could be accepted.
    public static func repaired(_ mesh: ImportedMesh, path: String,
                                linearDeflectionMM: Double = 0) -> ImportedMesh {
        repairedWithReport(mesh, path: path, linearDeflectionMM: linearDeflectionMM).mesh
    }

    /// The import as the hooked `TopOptKit.importMesh` will return it: today's import,
    /// then the gate, then the repair. Idempotent once the hook is in (a repaired mesh
    /// is watertight, so the gate stays closed).
    public static func importMesh(path: String,
                                  linearDeflectionMM: Double = 0) throws -> ImportedMesh {
        let mesh = try TopOptKit.importMesh(path: path, linearDeflectionMM: linearDeflectionMM)
        guard needsRepair(path: path, mesh: mesh) else { return mesh }
        return repaired(mesh, path: path, linearDeflectionMM: linearDeflectionMM)
    }

    /// The repair with its report. `reimport` re-tessellates `path` at a linear
    /// deflection (defaults to the core importer, bypassing any hook); injectable so a
    /// test can drive T2 without a file.
    public static func repairedWithReport(
        _ mesh: ImportedMesh, path: String, linearDeflectionMM: Double = 0,
        reimport: ((Double) throws -> ImportedMesh)? = nil
    ) -> (mesh: ImportedMesh, report: StepMeshRepairReport) {
        func report(_ pass: StepMeshRepairReport.Pass, _ out: ImportedMesh, dropped: Int,
                    deflection: Double? = nil) -> (mesh: ImportedMesh, report: StepMeshRepairReport) {
            (out, StepMeshRepairReport(pass: pass, droppedSlivers: dropped,
                                       linearDeflectionMM: deflection,
                                       stockTriangles: mesh.triangleCount,
                                       repairedTriangles: out.triangleCount))
        }
        guard needsRepair(path: path, mesh: mesh) else {
            return report(.notNeeded, mesh, dropped: 0)
        }
        // T1 — the stock tessellation minus its pole slivers.
        let t1 = droppingPoleSlivers(mesh)
        // Every face that owns a triangle with area must keep one. (A face id carried
        // ONLY by slivers has no area to keep; none of his parts has one.)
        let wantedFaces = faceIDsPresent(t1.mesh)
        if accepts(t1.mesh, faceCount: mesh.faceCount, faces: wantedFaces) {
            return report(.poleSlivers, t1.mesh, dropped: t1.dropped)
        }

        // T2 — the same file, finer, then T1.
        let base = linearDeflectionMM > 0 ? linearDeflectionMM : coreDefaultLinearDeflectionMM
        let load = reimport ?? { try stockImport(path: path, linearDeflectionMM: $0,
                                                 faceGeometry: mesh.faceGeometry) }
        for fraction in retessellationFractions {
            let d = base * fraction
            guard let finer = try? load(d) else { continue }
            let closed = droppingPoleSlivers(finer)
            if accepts(closed.mesh, faceCount: mesh.faceCount, faces: wantedFaces) {
                return report(.retessellated, closed.mesh, dropped: closed.dropped, deflection: d)
            }
        }
        return report(.gaveUp, mesh, dropped: 0)
    }

    // MARK: - T1

    /// `mesh` without its pole slivers: every triangle whose welded corners repeat.
    /// Vertices are untouched (no re-index); kept triangles keep their order and their
    /// face id. `watertight` is re-measured by core's own criterion.
    public static func droppingPoleSlivers(_ mesh: ImportedMesh) -> (mesh: ImportedMesh, dropped: Int) {
        let n = mesh.indices.count / 3
        let carriesFaces = mesh.faceIDs.count == n
        var indices: [Int32] = []
        indices.reserveCapacity(mesh.indices.count)
        var faceIDs: [Int32] = []
        faceIDs.reserveCapacity(carriesFaces ? n : 0)
        var dropped = 0
        for t in 0..<n {
            let a = mesh.indices[3 * t], b = mesh.indices[3 * t + 1], c = mesh.indices[3 * t + 2]
            if a == b || b == c || a == c { dropped += 1; continue }
            indices.append(a); indices.append(b); indices.append(c)
            if carriesFaces { faceIDs.append(mesh.faceIDs[t]) }
        }
        guard dropped > 0 else { return (mesh, 0) }
        let out = ImportedMesh(vertices: mesh.vertices, indices: indices,
                               faceIDs: carriesFaces ? faceIDs : mesh.faceIDs,
                               vertexCount: mesh.vertexCount,
                               triangleCount: indices.count / 3,
                               faceCount: mesh.faceCount,
                               watertight: isWatertight(indices: indices),
                               faceGeometry: mesh.faceGeometry,
                               pseudoFaces: mesh.pseudoFaces)
        return (out, dropped)
    }

    // MARK: - T2's importer

    /// core's STEP import at `linearDeflectionMM`, straight through the bridge (so it
    /// never re-enters a hooked `TopOptKit.importMesh`). Face geometry is per B-rep face
    /// and independent of the deflection, so the caller's copy is reused.
    public static func stockImport(path: String, linearDeflectionMM: Double,
                                   faceGeometry: [StepFaceGeometry]) throws -> ImportedMesh {
        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.import_part(std.string(path), linearDeflectionMM, &err)
        if !err.ok { throw TopOptError(message: String(err.message)) }
        return ImportedMesh(vertices: Array(raw.vertices), indices: Array(raw.indices),
                            faceIDs: Array(raw.face_ids),
                            vertexCount: Int(raw.vertex_count),
                            triangleCount: Int(raw.triangle_count),
                            faceCount: Int(raw.face_count),
                            watertight: raw.watertight,
                            faceGeometry: faceGeometry,
                            pseudoFaces: raw.pseudo_faces)
    }

    // MARK: - acceptance

    /// A pass is kept only if the mesh is closed AND consistently oriented AND encloses
    /// positive volume AND keeps the face count and every face id in `faces`.
    static func accepts(_ m: ImportedMesh, faceCount: Int, faces: Set<Int32>) -> Bool {
        m.triangleCount > 0
            && m.faceCount == faceCount
            && m.watertight
            && isClosedAndOriented(indices: m.indices)
            && signedVolume(m) > 0
            && faceIDsPresent(m).isSuperset(of: faces)
    }

    /// core's `check_watertight`: every undirected edge used by exactly two triangles.
    public static func isWatertight(indices: [Int32]) -> Bool {
        guard !indices.isEmpty else { return false }
        var uses: [UInt64: Int] = [:]
        uses.reserveCapacity(indices.count)
        forEachEdge(indices) { a, b in uses[undirected(a, b), default: 0] += 1 }
        return uses.values.allSatisfy { $0 == 2 }
    }

    /// Closed and consistently wound: every directed edge appears once and its reverse
    /// once. A folded or overlapping triangulation fails this even when it closes.
    public static func isClosedAndOriented(indices: [Int32]) -> Bool {
        guard !indices.isEmpty else { return false }
        var directed: [UInt64: Int] = [:]
        directed.reserveCapacity(indices.count)
        forEachEdge(indices) { a, b in directed[key(a, b), default: 0] += 1 }
        for (k, n) in directed {
            guard n == 1 else { return false }
            let a = UInt32(truncatingIfNeeded: k >> 32), b = UInt32(truncatingIfNeeded: k)
            guard directed[UInt64(b) << 32 | UInt64(a)] == 1 else { return false }
        }
        return true
    }

    /// Divergence-theorem volume (mm³), accumulated in Double; positive when wound outward.
    public static func signedVolume(_ m: ImportedMesh) -> Double {
        var v6 = 0.0
        let v = m.vertices
        for t in 0..<(m.indices.count / 3) {
            let i = Int(m.indices[3 * t]) * 3, j = Int(m.indices[3 * t + 1]) * 3,
                k = Int(m.indices[3 * t + 2]) * 3
            let ax = Double(v[i]), ay = Double(v[i + 1]), az = Double(v[i + 2])
            let bx = Double(v[j]), by = Double(v[j + 1]), bz = Double(v[j + 2])
            let cx = Double(v[k]), cy = Double(v[k + 1]), cz = Double(v[k + 2])
            v6 += ax * (by * cz - bz * cy) + ay * (bz * cx - bx * cz) + az * (bx * cy - by * cx)
        }
        return v6 / 6
    }

    /// The pole slivers in a mesh: triangles whose corners repeat a vertex index.
    public static func poleSliverCount(_ m: ImportedMesh) -> Int {
        var n = 0
        for t in 0..<(m.indices.count / 3) {
            let a = m.indices[3 * t], b = m.indices[3 * t + 1], c = m.indices[3 * t + 2]
            if a == b || b == c || a == c { n += 1 }
        }
        return n
    }

    static func faceIDsPresent(_ m: ImportedMesh) -> Set<Int32> { Set(m.faceIDs) }

    private static func forEachEdge(_ indices: [Int32], _ body: (Int32, Int32) -> Void) {
        for t in 0..<(indices.count / 3) {
            let a = indices[3 * t], b = indices[3 * t + 1], c = indices[3 * t + 2]
            body(a, b); body(b, c); body(c, a)
        }
    }
    private static func key(_ a: Int32, _ b: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b))
    }
    private static func undirected(_ a: Int32, _ b: Int32) -> UInt64 {
        a < b ? key(a, b) : key(b, a)
    }
}
