// LatticeVariantAlternative — the latticed object an OPTIMIZE run produced for a
// rung, brought within reach of the app (task 2026-08-07-lattice-variants-on-screen).
//
// ═══════════════════════════════════════════════════════════════════════════
// THE GAP THIS CLOSES
// ═══════════════════════════════════════════════════════════════════════════
//
// A lattice optimize run produces TWO objects per accepted rung: the solid variant
// and its latticed alternative. The re-lattice path ("Lattice this") fetches its
// one latticed mesh (`RelatticeRunner.swift`, `variant_<vf>_lattice.stl`). The
// OPTIMIZE path fetched only a receipt, and only for the last rung, and only when
// the job asked for a region breakdown (`RemoteRun.fetchRegionCells`). So a
// lattice produced by an optimize run existed as numbers on a worker's disk and
// never as anything the app could name, show, weigh or export.
//
// The cost, measured on the maintainer's own run (worker job ca62f91cba4b422d):
// the app showed the recommended variant at 360 g with "Mesh: 358 g (est.)", while
// `variant_026_lattice.report.json` recorded `lattice_mass_grams: 246.38`. A
// 114 g lighter object was sitting beside it, unmentioned.
//
// ═══════════════════════════════════════════════════════════════════════════
// WHERE THE FACTS COME FROM — AND WHY NOT FROM THE MESH
// ═══════════════════════════════════════════════════════════════════════════
//
// The core prints one `LATTICE …` checkpoint line per rung as it finishes
// (run_job.cpp, the `emit_lattice` lambda's `stream_lines` branch), carrying the
// rung, the topology, the cell, the emitted triangle count, the composite margin,
// the verdict, and the two FILENAMES. The worker forwards any line it does not
// recognise as a typed `log` SSE event verbatim (topopt_worker.py `_line_to_event`
// falls through to `{"type": "log", "line": …}`), and RemoteRun dropped those at
// its `default: break`. So the announcement was always arriving; nothing read it.
// It is read here, in the app, which is why this task needed no protocol change
// and no worker change: the wire already carried it.
//
// *** THE MASS COMES FROM THE RECEIPT, NEVER FROM THE MESH. *** A latticed STL is
// an interpenetrating SOUP — struts weld through each other and through the solid
// companion body — so the divergence-theorem volume the app computes for a solid
// variant (`MeshExport.meshMassGrams`) double-counts every overlap and is simply
// wrong here. `lattice_mass_grams` in the per-variant certification receipt is the
// core's own voxel-basis accounting of the object it certified. That is the only
// honest number, so it is the one this type carries, and `massProvenance` says so
// on screen rather than leaving the user to assume it was weighed the same way.

import Foundation

// MARK: - the checkpoint line

/// One `LATTICE …` line from the CLI, as it reaches the app inside a `log` SSE
/// event. Pure parsing over the key=value token discipline core writes; unknown
/// keys are ignored and a missing key leaves its field at the documented default,
/// so a newer core that adds a token does not break an older app.
public struct LatticeCheckpoint: Equatable, Sendable {
    /// The ladder rung this lattice belongs to (`vf=`), the join key against the
    /// streamed variant. This is the REQUESTED fraction, which is also what names
    /// the files (`%03d` of vf × 100 — `lattice_base_name` in run_job.cpp).
    public let requestedVolumeFraction: Double
    public let topologyID: String
    public let cellMM: Double
    /// A GRADED run's line carries `graded=1` and a rho range instead of a single
    /// strut radius / density (the two line shapes in `emit_lattice`).
    public let graded: Bool
    public let latticedCells: Int
    public let triangles: Int
    /// The composite certification's worst-case margin for the LATTICED object.
    public let margin: Double
    /// The receipt's verdict for the latticed object. Independent of the solid
    /// rung's `accepted` — a rung whose solid passes can have a lattice that does
    /// not, and the app must never show one verdict for the other.
    public let accepted: Bool
    /// Basenames, as the worker serves them from `/jobs/{id}/files/{name}`. The
    /// CLI prints absolute paths; only the last component travels.
    public let reportName: String
    public let meshName: String

    /// Parse a CLI stdout line. Returns nil for anything that is not a LATTICE
    /// checkpoint, or one without the two filenames — an announcement we cannot
    /// act on is not an announcement.
    public static func parse(_ line: String) -> LatticeCheckpoint? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("LATTICE ") else { return nil }
        var kv: [String: String] = [:]
        for token in trimmed.dropFirst("LATTICE ".count).split(separator: " ") {
            guard let eq = token.firstIndex(of: "=") else { continue }
            kv[String(token[token.startIndex..<eq])] =
                String(token[token.index(after: eq)...])
        }
        guard let vf = kv["vf"].flatMap(Double.init) else { return nil }
        // A lattice with no mesh and no receipt is nothing the app can reach.
        guard let mesh = kv["mesh"].map(basename), !mesh.isEmpty,
              let report = kv["report"].map(basename), !report.isEmpty
        else { return nil }
        return LatticeCheckpoint(
            requestedVolumeFraction: vf,
            topologyID: kv["topology"] ?? "",
            cellMM: kv["cell_mm"].flatMap(Double.init) ?? 0,
            graded: kv["graded"] == "1",
            latticedCells: kv["cells"].flatMap(Int.init) ?? 0,
            triangles: kv["tris"].flatMap(Int.init) ?? 0,
            margin: kv["lattice_margin"].flatMap(Double.init) ?? 0,
            accepted: kv["lattice_accepted"] == "1",
            reportName: report, meshName: mesh)
    }

    private static func basename(_ p: String) -> String {
        (p as NSString).lastPathComponent
    }
}

// MARK: - the alternative itself

/// The latticed object for one rung: everything the app knows about it WITHOUT
/// having transferred its mesh. Deliberately mesh-free — see `LatticeMeshBudget`
/// for why the mesh is not simply fetched with everything else.
public struct LatticeVariantAlternative: Equatable, Sendable {
    public let requestedVolumeFraction: Double
    /// The worker-side filename, the handle for an on-demand transfer.
    public let meshName: String
    /// `lattice_mass_grams` from the per-variant certification receipt — the core's
    /// voxel-basis mass of the object it certified. 0 when the receipt could not be
    /// read, which the UI renders as "n/a" (never 0.0 g — the 111 invariant).
    public let massGrams: Double
    /// The receipt's own verdict for the LATTICED object.
    public let accepted: Bool
    /// The latticed object's worst-case composite margin.
    public let margin: Double
    public let triangleCount: Int
    /// The mesh's size on the worker, from the `Content-Length` of a ranged probe.
    /// 0 = not known (an older worker, a probe that failed). Drives the transfer
    /// decision, so "not known" is treated as "must be measured before promising".
    public let meshBytes: Int
    /// The raw per-variant certification receipt, for the strut/region readouts the
    /// results screen already knows how to render.
    public let receiptJSON: Data?

    public init(requestedVolumeFraction: Double, meshName: String, massGrams: Double,
                accepted: Bool, margin: Double, triangleCount: Int,
                meshBytes: Int, receiptJSON: Data?) {
        self.requestedVolumeFraction = requestedVolumeFraction
        self.meshName = meshName
        self.massGrams = massGrams
        self.accepted = accepted
        self.margin = margin
        self.triangleCount = triangleCount
        self.meshBytes = meshBytes
        self.receiptJSON = receiptJSON
    }

    /// WHERE THE MASS CAME FROM, in the words the screen uses. The solid variant's
    /// mass is a voxel count from `fields.bin`, and the caption beside it can offer
    /// a mesh-derived cross-check; the latticed mass can offer neither, because the
    /// latticed mesh is an interpenetrating soup with no well-defined enclosed
    /// volume. Saying so is the difference between a number and a claim.
    public static let massProvenance =
        "from the lattice certification receipt (voxel basis) — a latticed mesh is "
        + "an interpenetrating soup, so it has no enclosed volume to weigh"

    /// Read `lattice_mass_grams` / `lattice_accepted` / `lattice_margin_worst_case`
    /// out of a receipt. A key that is absent or JSON-null leaves the caller's
    /// fallback in place — a null margin means "this failure mode carries no load",
    /// which is not a number to display as 0.
    public static func receiptFacts(_ data: Data)
        -> (massGrams: Double, accepted: Bool?, margin: Double?) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else { return (0, nil, nil) }
        return ((obj["lattice_mass_grams"] as? Double) ?? 0,
                obj["lattice_accepted"] as? Bool,
                obj["lattice_margin_worst_case"] as? Double)
    }
}
