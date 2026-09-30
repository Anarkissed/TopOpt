// FlexibleReadiness — what stands between the drawing and a lattice, said at once and fixed
// in one tap (task 2026-09-29-flexible-screens, round 3 batch B, item 9; maintainer: "I
// can't make Lattice run").
//
// ★ HIS RULES. Blockers surface AT ONCE as a pop-up that SELECTS the face and says exactly
// what to choose, with 1–3 fix buttons; exiting after a couple of inputs must yield a
// lattice; Exit is blocked only when truly required, and then the fix is exceedingly
// stupid-proof.
//
// ★ WHAT BLOCKS (decisions): only what truly stops a lattice —
//   * no filament (a legacy project only),
//   * no pressed face,
//   * a pressed face core cannot stack,
//   * a pressed face with no weight (core: "weight must be > 0"),
//   * a core refusal with no automatic fix.
// ★ WHAT NEVER BLOCKS: a calibrate-first filament (9 of 10 — Exit builds a SHAPE-ONLY
// lattice, "<filament>: shape only — no squish predicted", his answer), more than four
// pressed faces (the walls use every face; the squish is shown on the 4 largest), and
// "still being designed" (Exit proceeds; the main page's pill says "Building…"), and — ★ ROUND 4
// (D2, his img 3: "you would absolutely squeeze the two sides together. One side wouldn't
// rest.") — TWO PRESSED FACES ON ONE STACK: inside one squeeze group they are a PINCH, built as
// two segments (FlexiblePinch); in two groups they are separate squeezes and the firmer wins
// (FlexibleGroupField). Round 3's "share a stack" blocker and its [Face 5 rests] [Face 3 rests]
// fixes (the "Rest the other end" machinery) are gone.
// ★ SILENT AUTO-FIXES (with a toast): temperature_not_tested → Auto; topology_no_data /
// honeycomb_side_stack → Gyroid.
//
// It replaces FlexibleLatticeGate.refusal, whose ORDER was the bug on his project: it said
// "calibrate-first" (which no longer blocks) before the one thing that did (faces 3 and 5).

import Foundation
import simd
import TopOptKit

/// One button on the fix pop-up.
public enum FlexibleFix: Hashable, Sendable {
    /// "[Face 5 rests]": the face becomes a resting face.
    case rest(Int)
    /// "[Remove it]": forget the face (only one no main-page group holds).
    case remove(Int)
    /// A number pad for the face's weight (kg).
    case weight(Int)
    /// "[Press Top A]": press the selected face (its group's weight, or the pad).
    case press(Int)
    /// "[varioShore TPU]": the filament with squish data.
    case pickFilament(id: String, name: String)
    /// ★ D2 REVIEW: "[Join the groups]": group `from`'s faces join group `into` (one squeeze; each
    /// face keeps its own curve).
    case joinGroups(from: Int, into: Int)
    /// "[Keep apart]": the groups stay separate (the pop-up closes).
    case keepApart

    /// The button's words (one line, ≤ 3 words where it can).
    public func title(_ name: (Int) -> String) -> String {
        switch self {
        case .rest(let r): return "\(name(r)) rests"
        case .remove(let r): return "Remove \(name(r))"
        case .weight: return "Type the weight"
        case .press(let r): return "Press \(name(r))"
        case .pickFilament(_, let n): return n
        case .joinGroups: return "Join the groups"
        case .keepApart: return "Keep apart"
        }
    }
}

/// One thing the readiness line / the pop-up says.
public struct FlexibleIssue: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case noFilament, noPressedFace, noStack, noWeight, refused, designFailed
        // never blocking
        case stillDesigning, shapeOnly, squishOnFour
        /// ★ D2 REVIEW: separate groups share material and one squishes less than designed
        /// (the firmer wins) — it POPS on the action that caused it, with [Join the groups]
        /// [Keep apart], but never blocks Exit.
        case groupsCompete
        /// The last build failed on these settings and this scene (core's words; batch B review).
        case buildFailed
    }
    /// Stable across recomputes: the kind and the faces it names (the pop-up shows a NEW one).
    public let id: String
    public let kind: Kind
    /// The face the pop-up selects and turns the camera to.
    public let region: Int?
    /// ONE sentence, no trailing full stop in the chip copy.
    public let oneLine: String
    public let blocking: Bool
    public let fixes: [FlexibleFix]
    /// ★ BATCH B REVIEW: the main page's pill form — short enough to read whole in the bottom
    /// bar at 11" portrait ("Fix: the weight on Face 3"); the full sentence is on the pop-up the
    /// pill opens.
    public let pill: String

    /// Every face the issue names — its own, then any other its fixes rest (the pop-up pulses
    /// them all and turns the camera to see them).
    public var named: [Int] {
        var out: [Int] = region.map { [$0] } ?? []
        for f in fixes { if case .rest(let r) = f, !out.contains(r) { out.append(r) } }
        return out
    }

    public init(id: String, kind: Kind, region: Int?, oneLine: String, blocking: Bool, fixes: [FlexibleFix],
                pill: String? = nil) {
        self.id = id; self.kind = kind; self.region = region; self.oneLine = oneLine
        self.blocking = blocking; self.fixes = fixes; self.pill = pill ?? oneLine
    }
}

/// A fix the app applies itself (a toast says so).
public struct FlexibleAutoFix: Equatable, Sendable {
    public enum What: Equatable, Sendable { case temperatureAuto, topologyGyroid }
    public let what: What
    public let toast: String
}

public struct FlexibleReadiness: Equatable, Sendable {
    public let issues: [FlexibleIssue]
    public let autoFixes: [FlexibleAutoFix]

    public var blocking: [FlexibleIssue] { issues.filter(\.blocking) }
    /// ★ D2 REVIEW: what the pop-up opens on — every blocker, and separate groups that compete
    /// for material (never a blocker; it pops on the action that caused it).
    public var popping: [FlexibleIssue] { issues.filter { $0.blocking || $0.kind == .groupsCompete } }
    /// The first competing group (the top line says it; its [Fix] reopens the choice).
    public var competing: FlexibleIssue? { issues.first { $0.kind == .groupsCompete } }
    public var isReady: Bool { blocking.isEmpty }
    /// The old gate's one sentence (kept for callers that only need "why not").
    public var refusal: String? { blocking.first?.oneLine }
    public var shapeOnly: Bool { issues.contains { $0.kind == .shapeOnly } }
    public var designing: Bool { issues.contains { $0.kind == .stillDesigning } }
    /// The last build failed (never blocks Exit — but the line is not "ready" green).
    public var buildFailed: Bool { issues.contains { $0.kind == .buildFailed } }

    /// The Settings page's top line (and the main page pill's text while something blocks).
    public var oneLine: String {
        let b = blocking
        if let first = b.first {
            return "\(b.count) thing\(b.count == 1 ? "" : "s") to fix: \(first.oneLine)"
        }
        if let failed = issues.first(where: { $0.kind == .buildFailed }) { return failed.oneLine }
        if let c = competing { return "Ready · \(c.pill)" }
        if let four = issues.first(where: { $0.kind == .squishOnFour }) {
            return "Ready · \(four.oneLine)"
        }
        return shapeOnly ? Self.readyShapeOnly : Self.ready
    }

    public static let ready = "Ready: Exit builds the lattice"
    public static let readyShapeOnly = "Ready: Exit builds a shape-only lattice"

    /// ★ BATCH B REVIEW: a failed build is SAID (it was invisible: "Building the lattice…" for
    /// ever) — core's first sentence, on the Settings line and the main page's pill.
    public static func buildFailedLine(_ error: String) -> String {
        "Couldn't build the lattice: \(firstSentence(error))"
    }

    /// "<filament>: shape only — no squish predicted" (his words for the calibrate-first lattice).
    public static func shapeOnlyLabel(_ filament: String) -> String {
        "\(FlexibleRowCopy.shortName(filament)): shape only — no squish predicted"
    }

    // MARK: the rule, as a value (testable without a model)

    public enum DesignState: Equatable, Sendable {
        /// Not asked yet / in flight.
        case pending
        case ok
        /// core refused the face (its code and sentence).
        case refused(code: String, reason: String)
        /// core threw for this face (its words).
        case failed(String)
    }

    public struct Face: Equatable, Sendable {
        public var region: Int
        public var weightKg: Double
        /// The stack exists.
        public var stacked: Bool
        /// core could not stack it (its words).
        public var stackError: String?
        public var design: DesignState
        /// The drawn map exists (a calibrate-first lattice needs only this).
        public var drawn: Bool
        /// The stack's area (mm²), for "the 4 largest".
        public var areaMM2: Double
        public init(region: Int, weightKg: Double, stacked: Bool, stackError: String? = nil,
                    design: DesignState = .pending, drawn: Bool = false, areaMM2: Double = 0) {
            self.region = region; self.weightKg = weightKg; self.stacked = stacked
            self.stackError = stackError; self.design = design; self.drawn = drawn; self.areaMM2 = areaMM2
        }
    }

    public struct Inputs {
        public var materialID: String?
        public var materialName: String?
        /// The filament has no squish data (calibrate-first): a shape-only lattice.
        public var calibrateFirst: Bool
        /// The filament a one-tap "pick a filament" chooses (the one with data).
        public var withData: (id: String, name: String)?
        /// ★ BATCH B REVIEW: any filament at all (the first in the catalogue) — the pick when
        /// none has data (it builds a shape-only lattice). nil only with no catalogue.
        public var anyFilament: (id: String, name: String)?
        /// ★ BATCH B REVIEW: the face that most likely carries weight (FlexibleReadiness.
        /// suggestedFace) — "no pressed face" with nothing selected had NO button.
        public var suggested: Int?
        public var pressed: [Face]
        public var nozzleIsAuto: Bool
        public var topologyIsGyroid: Bool
        public var selected: Int?
        /// The face's name as the panel writes it ("Top A", "Face 3").
        public var name: (Int) -> String
        /// No main-page group holds it (the trash is allowed).
        public var removable: (Int) -> Bool
        /// A main-page group gives it its weight (pressing needs no pad).
        public var inherited: (Int) -> Bool
        /// The last build failed on these settings and this scene (core's words).
        public var buildFailure: String?
        /// ★ D2 REVIEW: how many faces the pass squishes (its four slots keep a pinch whole, so it
        /// can be fewer than four); nil ⇒ the four largest.
        public var squishShown: Int?
        /// ★ D2 REVIEW: the groups that will squish less than designed once the lattice carries
        /// every group (FlexibleGroupEstimate) — said at once, never a blocker.
        public var groupMisses: [FlexibleGroupEstimate.Miss] = []
        /// A group's first face (the pop-up selects it) and its faces (named).
        public var groupRegions: (Int) -> [Int] = { _ in [] }

        public init(materialID: String?, materialName: String?, calibrateFirst: Bool,
                    withData: (id: String, name: String)?, pressed: [Face],
                    nozzleIsAuto: Bool = true, topologyIsGyroid: Bool = false, selected: Int? = nil,
                    name: @escaping (Int) -> String = { "Face \($0)" },
                    removable: @escaping (Int) -> Bool = { _ in true },
                    inherited: @escaping (Int) -> Bool = { _ in false }, buildFailure: String? = nil,
                    anyFilament: (id: String, name: String)? = nil, suggested: Int? = nil) {
            self.materialID = materialID; self.materialName = materialName; self.calibrateFirst = calibrateFirst
            self.withData = withData; self.pressed = pressed
            self.nozzleIsAuto = nozzleIsAuto; self.topologyIsGyroid = topologyIsGyroid; self.selected = selected
            self.name = name; self.removable = removable; self.inherited = inherited
            self.buildFailure = buildFailure
            self.anyFilament = anyFilament; self.suggested = suggested
        }
    }

    /// Codes core refuses with that the app fixes itself.
    public static let temperatureCodes: Set<String> = ["temperature_not_tested"]
    public static let topologyCodes: Set<String> = ["topology_no_data", "honeycomb_side_stack"]

    public static func evaluate(_ i: Inputs) -> FlexibleReadiness {
        var out: [FlexibleIssue] = []
        var auto: [FlexibleAutoFix] = []
        let name = i.name
        func restOrRemove(_ r: Int) -> [FlexibleFix] {
            i.removable(r) ? [.rest(r), .remove(r)] : [.rest(r)]
        }

        // 1. no filament — a legacy project only (New TopOpt picks one). ★ Every blocking issue
        // has a button (batch B review): the filament with data, else any filament (a
        // shape-only lattice); with no catalogue at all there is nothing to pick, and Exit is
        // not held on it (the build then says why)
        if i.materialID == nil {
            let pick = i.withData ?? i.anyFilament
            out.append(FlexibleIssue(id: "noFilament", kind: .noFilament, region: nil,
                                     oneLine: "Pick the filament you print with",
                                     blocking: pick != nil,
                                     fixes: pick.map { [.pickFilament(id: $0.id, name: $0.name)] } ?? [],
                                     pill: "Fix: pick a filament"))
        }
        // 2. no pressed face — the selected face, else the one most likely to carry weight
        if i.pressed.isEmpty {
            let target = i.selected ?? i.suggested
            out.append(FlexibleIssue(id: "noPressedFace", kind: .noPressedFace, region: target,
                                     oneLine: target.map { "Press \(name($0)) or tap the face that carries weight" }
                                        ?? "Tap the face that carries weight, then press it",
                                     blocking: true,
                                     fixes: target.map { [.press($0)] } ?? [],
                                     pill: "Fix: press the face that carries weight"))
        }
        // ★ ROUND 4 (D2): two pressed faces on one stack no longer block — a pinch inside a
        // squeeze group is two segments, two groups are separate squeezes (firmer wins)
        // 3–6. per pressed face
        for f in i.pressed {
            let r = f.region
            if let e = f.stackError {
                out.append(FlexibleIssue(id: "noStack|\(r)", kind: .noStack, region: r,
                                         oneLine: "\(name(r)) can't be squished here: \(firstSentence(e))",
                                         blocking: true, fixes: restOrRemove(r),
                                         pill: "Fix: \(name(r)) can't be squished"))
                continue
            }
            if !(f.weightKg > 0) {
                out.append(FlexibleIssue(id: "noWeight|\(r)", kind: .noWeight, region: r,
                                         oneLine: "How much weight presses \(name(r))?",
                                         blocking: true, fixes: [.weight(r)] + restOrRemove(r).prefix(1),
                                         pill: "Fix: the weight on \(name(r))"))
                continue
            }
            // a calibrate-first filament designs nothing — its lattice needs only the drawing
            guard !i.calibrateFirst else { continue }
            switch f.design {
            case .refused(let code, let reason):
                if temperatureCodes.contains(code), !i.nozzleIsAuto {
                    if !auto.contains(where: { $0.what == .temperatureAuto }) {
                        auto.append(FlexibleAutoFix(what: .temperatureAuto,
                                                    toast: "Nozzle temperature set to Auto — that one was never tested"))
                    }
                } else if topologyCodes.contains(code), !i.topologyIsGyroid {
                    if !auto.contains(where: { $0.what == .topologyGyroid }) {
                        auto.append(FlexibleAutoFix(what: .topologyGyroid,
                                                    toast: "Lattice set to Gyroid — \(name(r)) can't use that one"))
                    }
                } else {
                    out.append(FlexibleIssue(id: "refused|\(r)|\(code)", kind: .refused, region: r,
                                             oneLine: "\(name(r)): \(firstSentence(reason))",
                                             blocking: true, fixes: restOrRemove(r),
                                             pill: "Fix: \(name(r)) can't be designed"))
                }
            case .failed(let why):
                out.append(FlexibleIssue(id: "designFailed|\(r)", kind: .designFailed, region: r,
                                         oneLine: "\(name(r)): \(firstSentence(why))",
                                         blocking: true, fixes: restOrRemove(r),
                                         pill: "Fix: \(name(r)) can't be designed"))
            case .pending, .ok:
                break
            }
        }

        // never blocking
        if i.materialID != nil, i.calibrateFirst {
            out.append(FlexibleIssue(id: "shapeOnly", kind: .shapeOnly, region: nil,
                                     oneLine: shapeOnlyLabel(i.materialName ?? "This filament"),
                                     blocking: false, fixes: []))
        }
        let stillDesigning = i.pressed.contains { f in
            guard f.stackError == nil, f.weightKg > 0 else { return false }
            if !f.stacked { return true }
            return i.calibrateFirst ? !f.drawn : f.design == .pending
        }
        if stillDesigning, i.materialID != nil {
            out.append(FlexibleIssue(id: "stillDesigning", kind: .stillDesigning, region: nil,
                                     oneLine: "Still designing — Exit builds it when it lands",
                                     blocking: false, fixes: []))
        }
        if let e = i.buildFailure {
            out.append(FlexibleIssue(id: "buildFailed", kind: .buildFailed, region: nil,
                                     oneLine: buildFailedLine(e), blocking: false, fixes: []))
        }
        // ★ D2 REVIEW: separate groups whose shared material leaves one squishing less than he
        // drew — said AT ONCE (the pop-up opens on the action that caused it), with the choice
        for m in i.groupMisses {
            let faces = i.groupRegions(m.groupID)
            out.append(FlexibleIssue(id: "groupMiss|\(m.groupID)|\(m.firmerID)", kind: .groupsCompete, region: faces.first,
                                     oneLine: FlexibleRowCopy.groupCompetes(number: m.number, asBuiltMM: m.asBuiltMM,
                                                                            designedMM: m.designedMM, firmer: m.firmerNumber),
                                     blocking: false,
                                     fixes: [.joinGroups(from: m.groupID, into: m.firmerID), .keepApart],
                                     pill: FlexibleRowCopy.groupMissesEstimate(number: m.number, asBuiltMM: m.asBuiltMM, designedMM: m.designedMM)))
        }
        if i.pressed.count > FlexibleSquishField.maxFaces {
            let shown = min(FlexibleSquishField.maxFaces, i.squishShown ?? FlexibleSquishField.maxFaces)
            out.append(FlexibleIssue(id: "squishOnFour", kind: .squishOnFour, region: nil,
                                     oneLine: shown == FlexibleSquishField.maxFaces
                                        ? "Squish shown on the \(FlexibleSquishField.maxFaces) largest of \(i.pressed.count) faces"
                                        : "Squish shown on \(shown) of \(i.pressed.count) faces · pinches whole",
                                     blocking: false, fixes: []))
        }
        return FlexibleReadiness(issues: out, autoFixes: auto)
    }

    /// ★ THE FACE THAT MOST LIKELY CARRIES WEIGHT (batch B review): the face with the most
    /// area facing `up` (against gravity — the build direction); the largest when none faces
    /// up. One pass over the triangles. nil for a mesh with no face ids.
    public static func suggestedFace(mesh: ViewerMesh, up: SIMD3<Double>) -> (face: Int, centroid: SIMD3<Double>)? {
        guard !mesh.faceIDs.isEmpty, simd_length(up) > 1e-9 else { return nil }
        let u = simd_normalize(up)
        var area: [Int32: Double] = [:], upArea: [Int32: Double] = [:], centroid: [Int32: SIMD3<Double>] = [:]
        let pos = mesh.positions, idx = mesh.indices
        func p(_ i: UInt32) -> SIMD3<Double> {
            let k = Int(i) * 3
            return SIMD3(Double(pos[k]), Double(pos[k + 1]), Double(pos[k + 2]))
        }
        for t in 0..<min(mesh.triangleCount, mesh.faceIDs.count) {
            let a = p(idx[3 * t]), b = p(idx[3 * t + 1]), c = p(idx[3 * t + 2])
            let n = simd_cross(b - a, c - a) * 0.5
            let ar = simd_length(n)
            guard ar > 0 else { continue }
            let f = mesh.faceIDs[t]
            area[f, default: 0] += ar
            upArea[f, default: 0] += max(0, simd_dot(n, u))
            centroid[f, default: .zero] += (a + b + c) / 3 * ar
        }
        let facingUp = upArea.filter { $0.value > 1e-9 }
        let pool = facingUp.isEmpty ? area : facingUp
        guard let best = pool.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return nil }
        return (Int(best.key), (centroid[best.key] ?? .zero) / max(area[best.key] ?? 1, 1e-12))
    }

    /// core's sentences can run on; the line keeps the first one, without its full stop.
    static func firstSentence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: ". ") { t = String(t[..<r.lowerBound]) }
        while t.hasSuffix(".") { t.removeLast() }
        return t
    }
}

/// What the Exit button does (a value, so the button's call site can be pinned).
public enum FlexibleExitDecision: Equatable, Sendable {
    /// Save and close: the main page builds the lattice.
    case exit
    /// Blocked: the pop-up opens on this issue (its face selected).
    case fix(FlexibleIssue)

    public static func decide(_ r: FlexibleReadiness) -> FlexibleExitDecision {
        r.blocking.first.map { .fix($0) } ?? .exit
    }

    /// "Exit", or "Fix 1 thing" / "Fix 2 things" while something blocks.
    public static func title(_ r: FlexibleReadiness) -> String {
        let n = r.blocking.count
        return n == 0 ? "Exit" : "Fix \(n) thing\(n == 1 ? "" : "s")"
    }
}

/// ★ POP-UP SPAM (plan risk): the pop-up opens only on a NEW blocking issue that the user's
/// last action caused — never on recompute noise, never on opening a project that already
/// has one (its line says so; Exit opens the pop-up).
public struct FlexibleFixPrompt: Equatable, Sendable {
    /// The blocking ids seen at the last evaluation.
    public private(set) var known: Set<String> = []
    /// The action serial the last decision covered.
    public private(set) var coveredAction = 0
    /// ★ BATCH B REVIEW ("blockers surface AT ONCE as a pop-up"): a blocker that already stands
    /// when the page OPENS pops ONCE, as soon as the scene and designs settle — it had only
    /// turned the line orange. Then only a new one his action causes.
    public private(set) var openPending = false

    public init(actionSerial: Int = 0, popExisting: Bool = false) {
        coveredAction = actionSerial
        openPending = popExisting
    }

    /// The issue to pop, if any. `settled`: the scene is open and no design or stack is in
    /// flight (an action with no new issue is then covered, so later noise cannot claim it).
    public mutating func next(_ r: FlexibleReadiness, actionSerial: Int, settled: Bool) -> FlexibleIssue? {
        // ★ D2 REVIEW: separate groups that compete for material pop too — on the action that
        // caused them only (never on opening the page)
        let current = r.popping
        if openPending {
            guard settled else { return nil }
            openPending = false
            known = Set(current.map(\.id))
            coveredAction = max(coveredAction, actionSerial)
            return r.blocking.first
        }
        let fresh = current.filter { !known.contains($0.id) }
        known = Set(current.map(\.id))
        if let first = fresh.first, actionSerial > coveredAction {
            coveredAction = actionSerial
            return first
        }
        if settled { coveredAction = max(coveredAction, actionSerial) }
        return nil
    }

    /// ★ THE POP-UP SHOWS THE ISSUE AS IT IS NOW (batch B review): it kept the value it was
    /// opened with, so after he tapped the face it told him to, "no pressed face" still showed
    /// no [Press …] button. The same issue (by id) in the current readiness; nil once it is gone.
    public static func live(_ shown: FlexibleIssue, in r: FlexibleReadiness) -> FlexibleIssue? {
        r.popping.first { $0.id == shown.id }
    }
}

// MARK: - the model's readiness

extension FlexibleStageModel {

    /// The face's name as the panel writes it ("Top A", "Face 3").
    public func displayName(_ region: Int) -> String {
        let sector = regions.sector(region)
        return FlexibleRowCopy.faceName(sector: sector?.name,
                                        face: sector == nil ? region : regions.faces(of: region, mesh: project.viewerMesh).first ?? region)
    }

    /// The readiness inputs, read from the model's copies of core's results.
    public var readinessInputs: FlexibleReadiness.Inputs {
        let s = settings
        let calibrateFirst = material?.noPrediction != nil
        let pressed: [FlexibleReadiness.Face] = s.loadedFaces.map { f in
            let k = FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)
            let st = stacks[k]
            var design: FlexibleReadiness.DesignState = .pending
            // ★ ROUND 4 (D2): core's words about the face as it WAS wait for the run in flight
            let fresh = !designsInFlight || designedInputs[k] == Self.designInputKey(f)
            if let d = designs[k] {
                design = d.refusal.map { fresh ? .refused(code: $0.code, reason: text($0.reason)) : .pending } ?? .ok
            } else if let e = designErrors[k] {
                design = fresh ? .failed(text(e)) : .pending
            }
            return FlexibleReadiness.Face(region: f.faceRegionID, weightKg: f.weightKg, stacked: st != nil,
                                          stackError: stackErrors[k].map { text($0) }, design: design,
                                          drawn: liveS[k] != nil, areaMM2: st?.areaMM2 ?? 0)
        }
        let withData = catalogue.first { $0.noPrediction == nil }.map { (id: $0.id, name: $0.displayName) }
        let anyFilament = catalogue.first.map { (id: $0.id, name: $0.displayName) }
        var i = FlexibleReadiness.Inputs(
            materialID: s.materialID, materialName: material?.displayName ?? s.materialID,
            calibrateFirst: calibrateFirst, withData: withData, pressed: pressed,
            nozzleIsAuto: s.nozzleTempC == nil, topologyIsGyroid: s.topology == "gyroid",
            selected: selectedRegion,
            name: { [weak self] r in self?.displayName(r) ?? "Face \(r)" },
            removable: { _ in true },   // ★ ROUND 5 (S6): every face can be deleted from the Flexible setup
            inherited: { [mainPageLoads] r in mainPageLoads.entry(r)?.role == .pressed },
            buildFailure: latticeFailure, anyFilament: anyFilament,
            // only asked for when it is needed (nothing pressed, nothing selected)
            suggested: s.loadedFaces.isEmpty && selectedRegion == nil ? suggestedPressRegion() : nil)
        // ★ D2 REVIEW: the pass's slots keep a pinch whole; separate groups that compete
        if s.loadedFaces.count > FlexibleSquishField.maxFaces {
            let keys = loadedKeys.filter { stacks[$0] != nil }
            i.squishShown = FlexibleSqueezeGroups.squishSlots(Self.squishOrder(keys.map { (key: $0, areaMM2: stacks[$0]?.areaMM2 ?? 0) }),
                                                              pinchedWith: pinchedKeys(keys)).shown
        }
        if squeezeGroups.count > 1 {
            i.groupMisses = groupMisses
            let gs = squeezeGroups
            i.groupRegions = { id in gs.first { $0.id == id }?.regions ?? [] }
        }
        return i
    }

    public var readiness: FlexibleReadiness { FlexibleReadiness.evaluate(readinessInputs) }
}
