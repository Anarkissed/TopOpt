// OrganicVariantCache.swift — the on-disk cache of organic TOPOLOGIES (maintainer,
// 2026-09-04: "do the topology/thickness split and the on-disk cache first, with the
// beam lattice 3MF as the cache format").
//
// ★ WHAT IS CACHED IS THE FILE'S CONTENT: the spans core EMITS for one set of
// topology picks (cell size, window, traced/grown, shape fit, grade, layer height,
// the field identity) — baked to the render field in a second or two through the
// bridge. What is NOT in the key is thickness: the Thicker slider is a live radius on
// the march. The key also carries core's SHA and the bridge layout version, so a new
// core re-traces rather than serving a stale file.
//
// Lookup order: the app bundle (`OrganicSample/variants/<key>.3mf`, the cube's shipped
// defaults) → Application Support (`OrganicVariants/<key>.3mf`, what this device has
// traced) → nil (trace, then store).
import CryptoKit
import Foundation
import TopOptKit
import simd

public enum OrganicVariantCache {
    /// Bump when the bake layout or the key's meaning changes.
    public static let layoutVersion = 4

    /// The cache key for a sample's topology picks on a named field.
    public static func key(picks: OrganicSampleCube.Picks, fieldIdentity: String) -> String {
        var s = "v\(layoutVersion)|core=\(CoreFingerprint.value)|field=\(fieldIdentity)"
        // ★ NOT in the key: the stage (it only moves the organic spacing through the
        // allowable stress, which the sample never passes — measured 2026-09-04: a
        // Structural project missed the Aesthetic-keyed shipped variant for nothing)
        // and the strut width (live). Everything the trace reads is here.
        s += String(format: "|grow=%d|layer=%.4f|sep=%.4f-%.4f|overhang=%.2f|rho=%.4f-%.4f|fit=%d|only=%d|covered=%d|voxel=%.4f|repairs=%d|fillet=%d",
                    picks.grow ? 1 : 0, picks.layerHeightMM, picks.separationMinMM, picks.separationMaxMM,
                    picks.overhangDeg, picks.rhoMin, picks.rhoMax,
                    picks.shapeFit ? 1 : 0, picks.shapeFitOnly ? 1 : 0, picks.covered ? 1 : 0, picks.bakeVoxelMM,
                    picks.showRepairs ? 1 : 0, picks.overhangFillet ? 1 : 0)
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TopOpt/OrganicVariants", isDirectory: true)
    }

    /// The shipped defaults, if this build carries one for the key.
    public static func bundledURL(for key: String) -> URL? {
        Bundle.module.url(forResource: key, withExtension: "3mf", subdirectory: "OrganicSample/variants")
    }
    public static func cachedURL(for key: String) -> URL { directory.appendingPathComponent("\(key).3mf") }

    /// Where a hit came from — the banner and the census say it.
    public enum Source: String, Sendable { case bundle, device }

    public static func load(key: String) -> (doc: OrganicBeamLattice3MF.Document, source: Source)? {
        if let u = bundledURL(for: key), let d = try? Data(contentsOf: u), let doc = OrganicBeamLattice3MF.read(d) {
            return (doc, .bundle)
        }
        let u = cachedURL(for: key)
        if let d = try? Data(contentsOf: u), let doc = OrganicBeamLattice3MF.read(d) { return (doc, .device) }
        return nil
    }

    @discardableResult
    public static func store(key: String, doc: OrganicBeamLattice3MF.Document) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let u = cachedURL(for: key)
            try OrganicBeamLattice3MF.write(doc).write(to: u, options: .atomic)
            return u
        } catch { return nil }
    }

    /// Bake a document's spans into the two render channels on the given grid.
    public static func bake(_ doc: OrganicBeamLattice3MF.Document, origin: SIMD3<Float>, voxelMM: Double,
                            dims: (Int, Int, Int), bandMM: Double, source: Source) -> OrganicBakedFields? {
        guard let b = TopOptKit.organicSpansField(spans: doc.spans, fieldDims: dims,
                                                  fieldOrigin: SIMD3<Double>(origin), fieldSpacingMM: voxelMM,
                                                  bandMM: bandMM) else { return nil }
        let sp = SIMD3<Float>(repeating: Float(voxelMM))
        let dist = LatticeVoxelGrid(nx: dims.0, ny: dims.1, nz: dims.2, origin: origin, spacing: sp, values: b.field)
        let srf = LatticeVoxelGrid(nx: dims.0, ny: dims.1, nz: dims.2, origin: origin, spacing: sp, values: b.surfaceField)
        let census = doc.metadata["census"] ?? ""
        let summary = "\(b.spanCount) struts, " + String(format: "%.0f mm — from the %@ (3MF beam lattice)", doc.totalLengthMM,
                                                          source == .bundle ? "shipped variant" : "device cache")
            + (census.isEmpty ? "" : " · " + census)
        return OrganicBakedFields(distance: dist, surface: srf, reachMM: b.reachMM, summary: summary,
                                  spanCount: b.spanCount, lengthMM: doc.totalLengthMM)
    }
}
