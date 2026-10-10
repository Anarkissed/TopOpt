// FlexibleMainPageLoads — the main page's loads and anchors, read as Flexible faces (task
// 2026-09-29-flexible-screens, round 3, item 1.2: "weight comes from the main page").
//
// ★ ONE SOURCE OF TRUTH: THE GROUP (maintainer, 2026-09-29). A face in a main-page Load
// group arrives already pressed with the group's weight; an Anchor group's faces arrive
// resting. A weight typed on the Flexible page for such a face WRITES BACK to the group
// (`groupKg(forRegion:kg:)`), and every face of the group re-syncs, so the area split stays
// consistent. A weight typed for a face in no group is the user's own (weightFrom nil) and
// is never overwritten. A face a Load group presses is ALWAYS linked — also one pressed
// before it was linked (a pre-round-3 project's taps): see `adopt(into:)`. [Rests] on the
// Flexible page is his explicit choice and survives every re-sync; the trash is not offered
// for a face a group holds (`canRemove`).
//
// ★ THE MAPPING, per group (pure, headless):
//   * a face in `faces`: its split sectors if it has any (the sectors are the Flexible
//     regions), else the whole face;
//   * a region in `regionIDs`: a union recurses into its parts; a declared cut sector is that
//     sector (id 1_000_000 + FaceRegion id); anything else resolves to its member faces;
//   * a sector named explicitly wins over the same sector reached through its whole face.
// Weight is split by AREA, the way core spreads a group's force as one traction: region
// area / the group's area (a sector's area is its faces clipped to its cuts).
//
// ★ HOW HARD A FACE IS PRESSED: c = dot(F̂, load), load = into the face (core's R13 frame;
// the stack's when it exists, else the face's own inward normal). c ≥ cos 15° ⇒ the full
// share; 0 < c < cos 15° ⇒ an oblique press, the share × c (said in one line); c ≤ 0 ⇒ a
// pull or a sideways load is not a squish ⇒ ask.

import Foundation
import simd

public struct FlexibleMainPageLoads: Equatable {

    public enum Role: String, Equatable, Sendable { case pressed, rests, ask }

    public struct Entry: Equatable, Sendable {
        public let region: Int
        public let role: Role
        /// The weight this face carries (kg): the group's share, × c when oblique; 0 unless pressed.
        public let weightKg: Double
        public let groupID: UUID
        public let groupName: String
        /// The group's whole weight (kg), and this face's share of its area.
        public let groupKg: Double
        public let share: Double
        /// c = dot(F̂, load): 1 pushes straight in, ≤ 0 pulls or shears.
        public let pressFraction: Double
        /// How many Flexible regions the group spans.
        public let groupRegions: Int
        public var oblique: Bool { role == .pressed && pressFraction < FlexibleMainPageLoads.straightCos }
    }

    /// cos 15° — core's "same axis" angle (kSameAxisDeg).
    public static let straightCos = cos(15 * Double.pi / 180)

    public let entries: [Int: Entry]

    public init(entries: [Int: Entry] = [:]) { self.entries = entries }

    /// The main page's verdict for a region; nil ⇒ it is in no Load or Anchor group (ask).
    public func entry(_ region: Int) -> Entry? { entries[region] }

    /// Can the Flexible page forget this face? Not while a main-page group presses or anchors
    /// it — the next re-sync would bring it straight back (the group is the one truth).
    public func canRemove(_ region: Int) -> Bool {
        guard let e = entries[region] else { return true }
        return e.role == .ask
    }

    /// ★ ADOPT (the one source of truth: the group — maintainer, 2026-09-29). Materialise the
    /// main page's groups into the Flexible faces, IN PLACE:
    ///   * a face a Load group presses becomes pressed with its share, LINKED (weightFrom =
    ///     the group). That holds for a face pressed before it was linked too — a project
    ///     saved before round 3, whose old taps pressed every face at 10 kg: the group's
    ///     weight wins, so the main run and the Flexible job can never disagree;
    ///   * a face he marked RESTS on this page (unlinked, not pressed) keeps his choice — the
    ///     panel says in one line that the main page still presses it;
    ///   * an Anchor group's faces rest, linked; a face he pressed there himself is kept;
    ///   * a linked face whose group no longer presses or anchors it keeps its role and weight
    ///     as his own (unlinked).
    /// Returns the old weight of every face whose OWN weight the group replaced (the panel
    /// says so in one line).
    @discardableResult
    public func adopt(into s: inout FlexibleStageSettings) -> [Int: Double] {
        var relinked: [Int: Double] = [:]
        for e in entries.values.sorted(by: { $0.region < $1.region }) {
            switch e.role {
            case .pressed:
                if var f = s.face(e.region) {
                    if f.weightFrom == nil && !f.isLoaded { continue }          // his Rests
                    if f.weightFrom == nil, abs(f.weightKg - e.weightKg) > 1e-9 { relinked[e.region] = f.weightKg }
                    f.role = "loaded"; f.weightKg = e.weightKg; f.weightFrom = e.groupID
                    s.setFace(f)
                } else {
                    s.setFace(FlexibleFaceSettings(faceRegionID: e.region, weightKg: e.weightKg, weightFrom: e.groupID))
                }
            case .rests:
                if var f = s.face(e.region) {
                    guard f.weightFrom != nil else { continue }                // his own choice
                    f.role = "resting"; f.weightFrom = e.groupID
                    s.setFace(f)
                } else {
                    s.setFace(FlexibleFaceSettings(faceRegionID: e.region, role: "resting", weightFrom: e.groupID))
                }
            case .ask:
                break
            }
        }
        for f in s.faces where f.weightFrom != nil {
            if let e = entries[f.faceRegionID], e.role != .ask { continue }
            var g = f; g.weightFrom = nil; s.setFace(g)
        }
        return relinked
    }

    /// The group weight that gives `region` a share of `kg` (the write-back of a weight typed
    /// on the Flexible page), or nil when the region's weight is not the group's.
    public func groupKg(forRegion region: Int, kg: Double) -> Double? {
        guard let e = entries[region], e.role == .pressed, e.share > 0 else { return nil }
        let factor = e.oblique ? e.pressFraction : 1
        guard factor > 0 else { return nil }
        return kg / (e.share * factor)
    }

    /// Every region of every Load / Anchor group (see the file comment).
    /// `load(region)`: core's into-the-face direction when its stack exists; else the face's
    /// own inward normal is used (R13's frame on a flat face).
    public static func derive(groups: [SelectionGroup], force: ForceModel, faceRegions: FaceRegionModel,
                              mesh: ViewerMesh, regions: FlexibleRegions,
                              load: (Int) -> SIMD3<Double>? = { _ in nil }) -> FlexibleMainPageLoads {
        let faceArea = FaceRegionGeometry.faceAreas(in: mesh)
        var sectorsOfFace: [FaceID: [FaceRegion]] = [:]
        for s in regions.sectors {
            for f in FaceRegionGeometry.members(of: s, in: mesh) { sectorsOfFace[f, default: []].append(s) }
        }
        func expand(face f: FaceID) -> [(id: Int, specific: Bool)] {
            let secs = sectorsOfFace[f] ?? []
            return secs.isEmpty ? [(Int(f), false)] : secs.map { (FlexibleRegions.wireID($0), false) }
        }
        func expand(region r: RegionID, depth: Int = 0) -> [(id: Int, specific: Bool)] {
            guard depth < 16, let reg = faceRegions.region(r) else { return [] }
            if reg.isUnionOfParts { return reg.parts.flatMap { expand(region: $0, depth: depth + 1) } }
            if reg.isCut, regions.sectors.contains(where: { $0.id == reg.id }) { return [(FlexibleRegions.wireID(reg), true)] }
            return FaceRegionGeometry.members(of: reg, in: mesh).flatMap { expand(face: $0) }
        }
        func area(_ id: Int) -> Double {
            guard let sec = regions.sector(id) else { return faceArea[FaceID(id)] ?? 0 }
            var a = 0.0
            let members = Set(FaceRegionGeometry.members(of: sec, in: mesh))
            for t in 0..<mesh.triangleCount where t < mesh.faceIDs.count && members.contains(mesh.faceIDs[t]) {
                let p = (0..<3).map { j -> SIMD3<Double> in
                    let b = Int(mesh.indices[3 * t + j]) * 3
                    return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
                }
                a += SurfacePatternAxis.polygonArea(SurfacePatternAxis.clipPolygon(p, to: sec.cuts))
            }
            return a
        }
        func inward(_ id: Int) -> SIMD3<Double>? {
            if let l = load(id), simd_length(l) > 1e-9 { return simd_normalize(l) }
            var acc = SIMD3<Double>.zero
            for f in regions.faces(of: id, mesh: mesh) {
                if let n = mesh.faceNormal(Int32(f)) { acc += SIMD3<Double>(n) * (faceArea[FaceID(f)] ?? 1) }
            }
            return simd_length(acc) > 1e-9 ? -simd_normalize(acc) : nil
        }
        func groupNormal(_ g: SelectionGroup) -> SIMD3<Double>? {
            var acc = SIMD3<Double>.zero
            var faces = g.faces
            for r in g.regionIDs { if let reg = faceRegions.region(r) { faces += FaceRegionGeometry.members(of: reg, in: mesh) } }
            for f in faces { if let n = mesh.faceNormal(f) { acc += SIMD3<Double>(n) } }
            return simd_length(acc) > 1e-9 ? simd_normalize(acc) : nil
        }
        var out: [Int: Entry] = [:]
        var specificity: [Int: Bool] = [:]
        for g in groups {
            let kind = force.kind(for: g.id)
            guard kind.isAnchor || kind.isLoad else { continue }
            var list: [(id: Int, specific: Bool)] = []
            for f in g.faces { list += expand(face: f) }
            for r in g.regionIDs { list += expand(region: r) }
            // one entry per region, the explicit sector winning within the group too
            var seen: [Int: Bool] = [:]
            for e in list { seen[e.id] = (seen[e.id] ?? false) || e.specific }
            let ids = seen.keys.sorted()
            let areas = Dictionary(uniqueKeysWithValues: ids.map { ($0, area($0)) })
            let total = areas.values.reduce(0, +)
            let kg = kind.weightKg ?? 0
            let dir: SIMD3<Double>? = {
                switch kind.loadDirection {
                case .gravity?: return SIMD3<Double>(force.gravity ?? SIMD3<Float>(0, 0, -1))
                case .push?: return groupNormal(g).map { -$0 }
                case .pull?: return groupNormal(g)
                case nil: return nil
                }
            }()
            for id in ids {
                let specific = seen[id] ?? false
                // a sector named explicitly wins over the same sector reached through its face
                if let prior = specificity[id], prior && !specific { continue }
                let share = total > 0 ? (areas[id] ?? 0) / total : 1 / Double(max(1, ids.count))
                var role: Role = kind.isAnchor ? .rests : .ask
                var c = 0.0, w = 0.0
                if kind.isLoad, let d = dir, simd_length(d) > 1e-9, let l = inward(id) {
                    c = simd_dot(simd_normalize(d), l)
                    if c >= straightCos { role = .pressed; w = kg * share }
                    else if c > 1e-6 { role = .pressed; w = kg * share * c }
                }
                out[id] = Entry(region: id, role: role, weightKg: w, groupID: g.id, groupName: g.name,
                                groupKg: kg, share: share, pressFraction: c, groupRegions: ids.count)
                specificity[id] = specific
            }
        }
        return FlexibleMainPageLoads(entries: out)
    }
}
