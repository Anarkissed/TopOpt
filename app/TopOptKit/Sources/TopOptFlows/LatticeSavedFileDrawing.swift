// LatticeSavedFileDrawing — ★ notes25 (362's numbers investigation, notes25/numbers/REPORT.md, its last row): his rule 11-19,
// amended 11-21: "The drawing follows the print file. Always." whenever Print-accurate preview is on. The strengthening (thicker
// struts, braces: additions.bin) goes only to the Mac's print-file job, so the iPad's own exact preview never has it: after a
// Lattice run the Lattice stage drew the lattice WITHOUT the strengthening (Results drew the file, with it).
//
// So with Print-accurate preview on and the version's print file made for exactly the settings on screen (same version,
// nothing changed since), the Lattice stage draws THAT file's lattice — the triangles after the solid's in the result's own
// mesh (core's "base_triangles" in the report), through the same path the Mac's print-accurate file is drawn by
// (`LatticeFileMesh`, `LatticeLayoutPreview.showFile`). A change of the settings lays the iPad's own preview again, as today.
import Foundation
import TopOptKit

enum LatticeSavedFile {
    /// The report's "base_triangles": the file's first triangles are the solid's (the part, its skins), every one after a weave
    /// shell. nil for a file without them (a regular lattice's STL).
    static func baseTriangles(_ o: OptimizeOutcome) -> Int? {
        guard let d = o.reportJSON, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return (j["base_triangles"] as? NSNumber)?.intValue
    }

    /// The saved print file's lattice, ready to draw; nil when the result carries none. Blocking: off the main thread.
    static func mesh(_ o: OptimizeOutcome, token: Int) throws -> LatticeFileMesh? {
        guard let base = baseTriangles(o), let v = o.variants.first(where: { $0.accepted }) ?? o.variants.first,
              !v.meshIndices.isEmpty else { return nil }
        return try LatticeFileMesh.make(vertices: v.meshVertices, indices: v.meshIndices, baseTriangles: base, token: token)
    }

    /// Whether the saved file is the lattice to draw now: Print-accurate preview on, an Organic lattice laid (not laying) for
    /// these settings and not the file already, and a print file made for exactly these settings.
    static func drawn(printAccurate: Bool, organic: Bool, laid: Bool, laying: Bool, showsFile: Bool, madeForNow: Bool) -> Bool {
        printAccurate && organic && laid && !laying && !showsFile && madeForNow
    }
}

extension LatticeSavedResult {
    /// ★ notes25: the version's print file's result when it was made from the settings on screen now (what it ran with, saved
    /// with it, is the version's settings now); nil otherwise, or while a run goes.
    @MainActor
    public static func madeForNow(_ p: ProjectModel, ranWith: ProjectSnapshot?) -> OptimizeOutcome? {
        guard p.run.phase != .running, let o = p.run.outcome(lattice: true), let ranWith,
              let now = p.snapshot(savedAt: ranWith.savedAt), LibrarySettings.same(ranWith, now) else { return nil }
        return o
    }
}

/// Makes a saved print file's lattice ready (off the main thread) and draws it, once per result and lattice on screen.
@MainActor
final class LatticeSavedFileDrawing {
    static let shared = LatticeSavedFileDrawing()

    /// The result and the lattice on screen last asked for (a second ask for the same is nothing).
    private var asked: (version: UUID, report: Int, bars: Int)?
    private var making: Task<Void, Never>?
    /// Saved files drawn (a test's count).
    private(set) var drawnCount = 0

    func draw(_ o: OptimizeOutcome, project p: ProjectModel, preview: LatticeLayoutPreview, stress: LatticeLayoutPreview.Stress) {
        guard let bars = preview.bars?.token else { return }
        let key = (p.id, o.reportJSON?.hashValue ?? 0, bars)
        if let a = asked, a.version == key.0, a.report == key.1, a.bars == key.2 { return }
        asked = key
        making?.cancel()
        let token = Int(Date().timeIntervalSince1970)
        making = Task { @MainActor [weak self] in
            let mesh = await Task.detached(priority: .userInitiated) { try? LatticeSavedFile.mesh(o, token: token) }.value
            // (the lattice on screen moved on meanwhile: nothing)
            guard let self, let mesh, !Task.isCancelled, preview.bars?.token == bars else { return }
            if preview.showFile(mesh, project: p, stress: stress) { self.drawnCount += 1 }
        }
    }

    /// Tests only.
    func reset() { making?.cancel(); making = nil; asked = nil; drawnCount = 0 }
}
