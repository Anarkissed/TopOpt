// OrganicBareVines — ★ notes30 (the reviewer's ruling with the owner's approval, 2026-11-26; core OS19, "the interim guard"):
// in an Organic part's strength check, when more than 1 % of a load lands on bare vines (the weave right under a loaded face),
// the check refuses to judge it: `fail_reason` "load_on_bare_lattice", with `load_on_frame_n`, `load_total_n`, `load_share`,
// `load_on_lattice_at` (where it lands, the part's own mm) and `fail_text`; strengthen.json stops before any round with the
// same code (thicker struts never cure it). Once the loaded face is covered — a Solid finish, or a Protect skin — its strength
// can be checked.
//
// What the app does with it, every place that reads the Organic strength result:
//   * the certify wizard: ONE pinned pop-up (Next/Skip/Solve, his design 11-19), its line to where the load lands; Solve opens
//     the CENTRED pop-up below, its two offers the loaded face's Protect skin and its Solid finish (the app's own names: the
//     Role row's "Protect skin", the Organic Finish row's "Solid");
//   * ★ LatticeReview's ruling (2026-11-26): PROTECT SKIN FIRST — the first button, and first in every line that names the
//     two (a Solid finish is as thick as the printer's walls, about 1 mm, and may be under two of the check's voxels; it stays
//     offered and is not thickened);
//   * Results: the Checks line and Details › Strength say what lands where, never a margin (the place lit, core's sentence
//     behind the (i));
//   * the print file's line and the strengthening's line: the same words.
// His rules: positive words; centred pop-ups only; captions five words at most; 44 pt targets; the place, never a face number.
import Foundation
import simd

public enum OrganicBareVines {
    /// Core's `fail_reason`, and strengthen.json's `code`.
    public static let reason = "load_on_bare_lattice"
    /// ★ The centred pop-up's words, exactly (core's `fail_text`; the reviewer's sentence).
    public static let text = "A load lands on bare vines. Give the loaded face a Solid finish or a protected skin so its strength can be checked."
    /// The pop-up's and the wizard card's title, and the Checks line's (five words at most).
    public static let title = "Load on bare vines"
    /// The two offers, Protect skin first (LatticeReview 11-26): the Role row's "Protect skin", and the Organic Finish row's
    /// "Solid" (never the plain "Skin").
    public static let protectSkin = LatticeSetupCopy.protectSkin
    public static let solidFinish = "Solid finish"
    /// The pop-up's dismiss (the wizard card stays, its Skip with it).
    public static let notNow = "Not now"
    /// The wizard card's advice line (the setting now, and what to try: Protect skin first).
    public static let advice = "The loaded face is bare vines now. Try a Protect skin or a Solid finish."
    /// The print file's one line (LatticeFileStrength.line) and the strengthening's.
    public static let line = "A load lands on bare vines · a Protect skin or a Solid finish on its face fixes it"
    /// Results' Checks line: its detail (five words) and its open row's line.
    public static let checkDetail = "Fix: Protect skin or Solid"
    public static let checkMore = "Where it lands is lit on the part"
    /// Details › Strength: the row in the "Holds" row's place.
    public static let rowLabel = "Load lands on"
    public static let rowValue = "Bare vines"

    /// ★ RED CONTROL (OrganicBareVinesTests, OrganicBareVinesHostedTests): the app reads the strength block as before notes30 —
    /// the reason unknown, no issue, no pop-up.
    nonisolated(unsafe) public static var controlUnread = false
    /// ★ RED CONTROL (OrganicBareVinesHostedTests): the pop-up's offers in the order before LatticeReview's ruling (Solid first).
    nonisolated(unsafe) public static var controlSolidFirst = false

    /// What core said with the reason.
    public struct Found: Equatable, Sendable {
        /// The load the check would put on the vines, and the whole load (N).
        public var onFrameN: Double?
        public var totalN: Double?
        /// The vines' share of the material where the load presses (0…1).
        public var share: Double?
        /// Where it lands (model mm), when core said so.
        public var at: SIMD3<Double>?
        /// Core's sentence (`fail_text`), else the app's copy of it.
        public var text: String
        /// ★ notes30 depth (LatticeReview's key, organic-engine 9850d951): the depth of solid under the loaded face that clears
        /// the check (`solid_depth_needed_mm`, 1.5 of its voxels, measured); nil: an older worker's core did not say.
        public var depthNeededMM: Double? = nil
    }

    /// The strength block's reading, or nil when its reason is another (or under the RED control).
    public static func found(strength s: [String: Any]) -> Found? {
        guard !controlUnread, s["fail_reason"] as? String == reason else { return nil }
        func n(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        let at = (s["load_on_lattice_at"] as? [NSNumber]).flatMap {
            $0.count == 3 ? SIMD3($0[0].doubleValue, $0[1].doubleValue, $0[2].doubleValue) : nil
        }
        let said = (s["fail_text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text
        return Found(onFrameN: n(s["load_on_frame_n"]), totalN: n(s["load_total_n"]), share: n(s["load_share"]), at: at,
                     text: said, depthNeededMM: depth(s))
    }

    /// Core's `solid_depth_needed_mm` (a strength block, or strengthen.json when it carries it), nil when absent or not a depth.
    public static func depth(_ o: [String: Any]?) -> Double? {
        guard let d = (o?["solid_depth_needed_mm"] as? NSNumber)?.doubleValue, d.isFinite, d > 0 else { return nil }
        return d
    }

    // MARK: LatticeReview's wizard rule (2026-11-26, with the depth key)

    /// ★ RED CONTROL (OrganicBareVinesTests, OrganicBareVinesHostedTests): the depth key ignored — today's offers (both, the
    /// page's Protect skin depth).
    nonisolated(unsafe) public static var controlNoDepth = false
    /// A Protect skin offered at least this deep (the page's own default), and on this step.
    public static let skinFloorMM = 4.0, skinStepMM = 0.5

    /// What the pop-up offers for a result.
    public struct Offers: Equatable, Sendable {
        /// Solid finish is offered (its wall, the printer's own, is at least the depth needed).
        public var solid: Bool
        /// The Protect skin's depth (mm); nil: the page's depth, as before the key.
        public var skinDepthMM: Double?
    }

    /// ★ LatticeReview's rule: with core's depth `needed`, Solid finish ONLY when its wall (`wallMM`, the printer's wall ring:
    /// the cover a Solid finish lays) is at least `needed`; Protect skin at max(4 mm, `needed` rounded UP to 0.5 mm). Without
    /// the key (an older worker): both offered, the page's Protect skin depth — today's behaviour.
    public static func offers(depthNeededMM needed: Double?, wallMM: Double) -> Offers {
        guard !controlNoDepth, let d = needed, d > 0 else { return Offers(solid: true, skinDepthMM: nil) }
        let up = ((d / skinStepMM) - 1e-9).rounded(.up) * skinStepMM
        return Offers(solid: wallMM >= d - 1e-9, skinDepthMM: Swift.max(skinFloorMM, up))
    }

    /// The wizard card's advice line for `offers` (Protect skin first; its depth when the key gave one; Solid only when offered).
    public static func adviceLine(_ o: Offers) -> String {
        guard let d = o.skinDepthMM else { return advice }
        let skin = "a Protect skin " + OrganicCertifyCopy.mm(d) + " mm deep"
        return "The loaded face is bare vines now. Try " + skin + (o.solid ? " or a Solid finish." : ".")
    }

    /// ★ 362 (11-26): the offers for what core said, with the printer's wall (the cover a Solid finish lays) when the page knows
    /// it; an unknown wall offers no Solid when the key is there (only the fix always offered is named).
    public static func offers(_ f: Found, wallMM: Double?) -> Offers {
        offers(depthNeededMM: f.depthNeededMM, wallMM: wallMM ?? 0)
    }

    /// ★ 362 (11-26): Results' Checks line names only the fixes offered — Solid not offered: "Fix: Protect skin 4.5 mm" (five
    /// words); otherwise, and with no key, today's "Fix: Protect skin or Solid".
    public static func checkDetailLine(_ o: Offers) -> String {
        guard !o.solid, let d = o.skinDepthMM else { return checkDetail }
        return "Fix: Protect skin " + OrganicCertifyCopy.mm(d) + " mm"
    }

    /// ★ 362 (11-26): the print file's line names only the fixes offered — Solid not offered: the Protect skin and its depth;
    /// otherwise, and with no key, today's line.
    public static func printLine(_ o: Offers) -> String {
        guard !o.solid, let d = o.skinDepthMM else { return line }
        return "A load lands on bare vines · a Protect skin " + OrganicCertifyCopy.mm(d) + " mm deep on its face fixes it"
    }

    /// ★ 362's review (11-26): a load on bare vines has no valid margin — what stands in a margin's place for its result, the
    /// words its Checks line leads with, everywhere a number like "2.00×" would show (Results' list row and Compare, Details ›
    /// Strength and Scenarios, the Library's cards, rows and Compare, the orientation check's columns). nil: the result's margin
    /// shows as before (another reason, no strength block, or the RED control).
    public static func marginWords(report r: [String: Any]?) -> String? {
        guard let s = r?["strength"] as? [String: Any], found(strength: s) != nil else { return nil }
        return title
    }
    public static func marginWords(reportJSON d: Data?) -> String? {
        guard let d, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return marginWords(report: o)
    }

    /// The point of triangle (a, b, c) nearest `p` (Ericson, Real-Time Collision Detection §5.1.5: by the Voronoi regions of
    /// its corners, edges and face).
    static func closest(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let sum = va + vb + vc
        guard abs(sum) > 1e-300 else { return a }   // a degenerate triangle: its first corner
        return a + ab * (vb / sum) + ac * (vc / sum)
    }

    /// ★ The centred pop-up (his 11-20 rule: never a line at the bottom): the sentence, then Protect skin (first, LatticeReview
    /// 11-26), Solid finish, Not now. `solid` nil (LatticeReview's depth rule: its wall is thinner than the depth needed): Protect
    /// skin and Not now only.
    @MainActor public static func offer(skin: @escaping () -> Void, solid: (() -> Void)?) {
        guard let solid else {
            AppPopups.shared.choose(title, text, first: (protectSkin, skin), second: nil, dismiss: notNow)
            return
        }
        if controlSolidFirst {   // the RED control: the order before the ruling
            AppPopups.shared.choose(title, text, first: (solidFinish, solid), second: (protectSkin, skin), dismiss: notNow)
            return
        }
        AppPopups.shared.choose(title, text, first: (protectSkin, skin), second: (solidFinish, solid), dismiss: notNow)
    }
}

// MARK: the two offers, on the part

extension ProjectModel {
    /// The loads the vines carry: Topology's load groups — with several, the one whose faces come nearest `at` (where core says
    /// the load lands); every one when the place or the mesh is unknown.
    public func bareVinesLoadGroups(near at: SIMD3<Double>?) -> [SelectionGroup] {
        let loads = selection.groups.filter { force.kind(for: $0.id).isLoad }
        guard loads.count > 1, let at, let mesh = viewerMesh else { return loads }
        func corner(_ t: Int) -> SIMD3<Double>? {
            let i = Int(mesh.indices[t])
            guard i < mesh.vertexCount else { return nil }
            return SIMD3(Double(mesh.positions[i * 3]), Double(mesh.positions[i * 3 + 1]), Double(mesh.positions[i * 3 + 2]))
        }
        // the distance from `at` to the group's surface (its nearest triangle; a place on a face is 0 from it, never a tie
        // with the face beside it, as the corners they share would be)
        func nearest(_ g: SelectionGroup) -> Double {
            let faces = Set(bareVinesFaces(of: g))
            var best = Double.infinity
            var t = 0
            while t + 2 < mesh.indices.count {
                let tri = t / 3
                if tri < mesh.faceIDs.count, faces.contains(mesh.faceIDs[tri]),
                   let a = corner(t), let b = corner(t + 1), let c = corner(t + 2) {
                    best = Swift.min(best, simd_distance(at, OrganicBareVines.closest(at, a, b, c)))
                }
                t += 3
            }
            return best
        }
        let ranked = loads.map { ($0, nearest($0)) }
        guard let first = ranked.min(by: { $0.1 < $1.1 }), first.1.isFinite else { return loads }
        return [first.0]
    }

    /// A group's faces, its own and its regions' (never a negative id).
    func bareVinesFaces(of g: SelectionGroup) -> [FaceID] {
        (g.faces + g.regionIDs.flatMap { surfaceResolvedFaces($0) }).filter { $0 >= 0 }
    }

    /// The Organic area whose finish covers the loaded face: the lattice group that holds it, else the only area; nil: the
    /// whole part's own look (the part latticed whole, or no area holds it).
    public func bareVinesArea(near at: SIMD3<Double>?) -> UUID? {
        guard !lattice.wholePart else { return nil }
        let loaded = Set(bareVinesLoadGroups(near: at).flatMap { bareVinesFaces(of: $0) })
        let areas = latticeAreaGroups
        if let holding = areas.first(where: { !Set(bareVinesFaces(of: $0)).isDisjoint(with: loaded) }) { return holding.id }
        return areas.count == 1 ? areas[0].id : nil
    }

    /// ★ Offer 1: the loaded face's area gets the Solid finish (the Organic Finish row's "Solid"). Returns the group it set
    /// (nil: the whole part's).
    @discardableResult
    public func giveLoadedFaceSolidFinish(near at: SIMD3<Double>?) -> UUID? {
        let g = bareVinesArea(near: at)
        var look = lattice.organicLook(group: g)
        look.finish = .solid
        lattice.setOrganicLook(look, group: g)
        return g
    }

    /// ★ Offer 2: the loaded face gets a Protect skin — a new lattice group holding it (taken from any lattice group that held
    /// it), its role Protect skin at `depthMM` (★ notes30 depth: LatticeReview's max(4 mm, the depth needed rounded up to 0.5
    /// mm)), else the page's depth, as the Role row sets it. Returns the group, or nil (no loaded face, or a Flexible part, whose
    /// lattice groups are Topology's).
    @discardableResult
    public func giveLoadedFaceProtectSkin(near at: SIMD3<Double>?, depthMM: Double? = nil) -> UUID? {
        guard usesLatticeList else { return nil }
        let loads = bareVinesLoadGroups(near: at)
        let faces = Array(Set(loads.flatMap { $0.faces.filter { $0 >= 0 } })).sorted()
        let regions = Array(Set(loads.flatMap(\.regionIDs))).sorted()
        guard !faces.isEmpty || !regions.isEmpty else { return nil }
        adoptLatticeListIfNeeded()
        var l = latticeList
        let id = l.addGroup()
        if !faces.isEmpty { l.addFaces(faces, to: id) }
        if !regions.isEmpty { l.addRegions(regions, to: id) }
        l.clearActive()   // the next tap starts its own group, as before
        latticeList = l
        lattice.skinGroups.insert(id)
        lattice.groupRoles[id] = .exclude   // a Protect skin group's role (the Role row's setLatticePickedRole(.skin))
        if let g = latticeGroups.first(where: { $0.id == id }) {
            for ref in latticeSelectableRefs(g) where lattice.selectableRoles[ref.key] != .off { lattice.selectableRoles[ref.key] = nil }
        }
        lattice.groupDepthMM[id] = LatticeSlabDepth.clamp(depthMM ?? lattice.paintDepthMM)
        syncForceGroups()
        return id
    }
}
