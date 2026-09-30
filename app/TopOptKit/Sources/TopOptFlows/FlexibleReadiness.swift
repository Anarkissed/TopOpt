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
//   * two pressed faces that share a stack (core refuses to assemble them: "push the same
//     material along the same axis"),
//   * a pressed face core cannot stack,
//   * a pressed face with no weight (core: "weight must be > 0"),
//   * a core refusal with no automatic fix.
// ★ WHAT NEVER BLOCKS: a calibrate-first filament (9 of 10 — Exit builds a SHAPE-ONLY
// lattice, "<filament>: shape only — no squish predicted", his answer), more than four
// pressed faces (the walls use every face; the squish is shown on the 4 largest), and
// "still being designed" (Exit proceeds; the main page says "Building the lattice…").
// ★ SILENT AUTO-FIXES (with a toast): temperature_not_tested → Auto; topology_no_data /
// honeycomb_side_stack → Gyroid.
//
// It replaces FlexibleLatticeGate.refusal, whose ORDER was the bug on his project: it said
// "calibrate-first" (which no longer blocks) before the one thing that did (faces 3 and 5).

import Foundation
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

    /// The button's words (one line, ≤ 3 words where it can).
    public func title(_ name: (Int) -> String) -> String {
        switch self {
        case .rest(let r): return "\(name(r)) rests"
        case .remove(let r): return "Remove \(name(r))"
        case .weight: return "Type the weight"
        case .press(let r): return "Press \(name(r))"
        case .pickFilament(_, let n): return n
        }
    }
}

/// One thing the readiness line / the pop-up says.
public struct FlexibleIssue: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case noFilament, noPressedFace, sharedStack, noStack, noWeight, refused, designFailed
        // never blocking
        case stillDesigning, shapeOnly, squishOnFour
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
    public var isReady: Bool { blocking.isEmpty }
    /// The old gate's one sentence (kept for callers that only need "why not").
    public var refusal: String? { blocking.first?.oneLine }
    public var shapeOnly: Bool { issues.contains { $0.kind == .shapeOnly } }
    public var designing: Bool { issues.contains { $0.kind == .stillDesigning } }

    /// The Settings page's top line (and the main page pill's text while something blocks).
    public var oneLine: String {
        let b = blocking
        if let first = b.first {
            return "\(b.count) thing\(b.count == 1 ? "" : "s") to fix: \(first.oneLine)"
        }
        if let four = issues.first(where: { $0.kind == .squishOnFour }) {
            return "Ready · \(four.oneLine)"
        }
        return shapeOnly ? Self.readyShapeOnly : Self.ready
    }

    public static let ready = "Ready: Exit builds the lattice"
    public static let readyShapeOnly = "Ready: Exit builds a shape-only lattice"

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
        public var pressed: [Face]
        /// core's stack conflicts among the pressed faces (a, b in core's order).
        public var conflicts: [(a: Int, b: Int)]
        public var nozzleIsAuto: Bool
        public var topologyIsGyroid: Bool
        public var selected: Int?
        /// The face's name as the panel writes it ("Top A", "Face 3").
        public var name: (Int) -> String
        /// No main-page group holds it (the trash is allowed).
        public var removable: (Int) -> Bool
        /// A main-page group gives it its weight (pressing needs no pad).
        public var inherited: (Int) -> Bool

        public init(materialID: String?, materialName: String?, calibrateFirst: Bool,
                    withData: (id: String, name: String)?, pressed: [Face], conflicts: [(a: Int, b: Int)],
                    nozzleIsAuto: Bool = true, topologyIsGyroid: Bool = false, selected: Int? = nil,
                    name: @escaping (Int) -> String = { "Face \($0)" },
                    removable: @escaping (Int) -> Bool = { _ in true },
                    inherited: @escaping (Int) -> Bool = { _ in false }) {
            self.materialID = materialID; self.materialName = materialName; self.calibrateFirst = calibrateFirst
            self.withData = withData; self.pressed = pressed; self.conflicts = conflicts
            self.nozzleIsAuto = nozzleIsAuto; self.topologyIsGyroid = topologyIsGyroid; self.selected = selected
            self.name = name; self.removable = removable; self.inherited = inherited
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

        // 1. no filament — a legacy project only (New TopOpt picks one)
        if i.materialID == nil {
            out.append(FlexibleIssue(id: "noFilament", kind: .noFilament, region: nil,
                                     oneLine: "Pick the filament you print with",
                                     blocking: true,
                                     fixes: i.withData.map { [.pickFilament(id: $0.id, name: $0.name)] } ?? []))
        }
        // 2. no pressed face
        if i.pressed.isEmpty {
            let target = i.selected
            out.append(FlexibleIssue(id: "noPressedFace", kind: .noPressedFace, region: target,
                                     oneLine: target.map { "Press \(name($0)) or tap the face that carries weight" }
                                        ?? "Tap the face that carries weight, then press it",
                                     blocking: true,
                                     fixes: target.map { [.press($0)] } ?? []))
        }
        // 3. two pressed faces sharing a stack — ★ FIRST among the per-face issues: on his
        // project it is THE one thing (the old gate said "calibrate-first" before it)
        var seenPairs = Set<String>()
        for c in i.conflicts {
            let (a, b) = (min(c.a, c.b), max(c.a, c.b))
            let key = "\(a)|\(b)"
            guard seenPairs.insert(key).inserted else { continue }
            out.append(FlexibleIssue(id: "sharedStack|\(key)", kind: .sharedStack, region: c.b,
                                     oneLine: "\(name(c.a)) and \(name(c.b)) press the same material",
                                     blocking: true,
                                     fixes: [.rest(c.b), .rest(c.a)]))
        }
        // 4–7. per pressed face
        for f in i.pressed {
            let r = f.region
            if let e = f.stackError {
                out.append(FlexibleIssue(id: "noStack|\(r)", kind: .noStack, region: r,
                                         oneLine: "\(name(r)) can't be squished here: \(firstSentence(e))",
                                         blocking: true, fixes: restOrRemove(r)))
                continue
            }
            if !(f.weightKg > 0) {
                out.append(FlexibleIssue(id: "noWeight|\(r)", kind: .noWeight, region: r,
                                         oneLine: "How much weight presses \(name(r))?",
                                         blocking: true, fixes: [.weight(r)] + restOrRemove(r).prefix(1)))
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
                                             blocking: true, fixes: restOrRemove(r)))
                }
            case .failed(let why):
                out.append(FlexibleIssue(id: "designFailed|\(r)", kind: .designFailed, region: r,
                                         oneLine: "\(name(r)): \(firstSentence(why))",
                                         blocking: true, fixes: restOrRemove(r)))
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
        if i.pressed.count > FlexibleSquishField.maxFaces {
            out.append(FlexibleIssue(id: "squishOnFour", kind: .squishOnFour, region: nil,
                                     oneLine: "Squish shown on the \(FlexibleSquishField.maxFaces) largest of \(i.pressed.count) faces",
                                     blocking: false, fixes: []))
        }
        return FlexibleReadiness(issues: out, autoFixes: auto)
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

    public init(actionSerial: Int = 0) { coveredAction = actionSerial }

    /// The issue to pop, if any. `settled`: no design or stack is in flight (an action with no
    /// new issue is then covered, so later noise cannot claim it).
    public mutating func next(_ r: FlexibleReadiness, actionSerial: Int, settled: Bool) -> FlexibleIssue? {
        let current = r.blocking
        let fresh = current.filter { !known.contains($0.id) }
        known = Set(current.map(\.id))
        if let first = fresh.first, actionSerial > coveredAction {
            coveredAction = actionSerial
            return first
        }
        if settled { coveredAction = max(coveredAction, actionSerial) }
        return nil
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
            if let d = designs[k] {
                design = d.refusal.map { .refused(code: $0.code, reason: text($0.reason)) } ?? .ok
            } else if let e = designErrors[k] {
                design = .failed(text(e))
            }
            return FlexibleReadiness.Face(region: f.faceRegionID, weightKg: f.weightKg, stacked: st != nil,
                                          stackError: stackErrors[k].map { text($0) }, design: design,
                                          drawn: liveS[k] != nil, areaMM2: st?.areaMM2 ?? 0)
        }
        let withData = catalogue.first { $0.noPrediction == nil }.map { (id: $0.id, name: $0.displayName) }
        let pressedIDs = Set(s.loadedFaces.map(\.faceRegionID))
        return FlexibleReadiness.Inputs(
            materialID: s.materialID, materialName: material?.displayName ?? s.materialID,
            calibrateFirst: calibrateFirst, withData: withData, pressed: pressed,
            // ★ a pair core found BEFORE his last action may name a face that no longer presses
            // (he just rested it): the line and the pop-up clear at once, not when the
            // pipeline next lands
            conflicts: conflicts.filter { pressedIDs.contains($0.faceA) && pressedIDs.contains($0.faceB) }
                .map { (a: $0.faceA, b: $0.faceB) },
            nozzleIsAuto: s.nozzleTempC == nil, topologyIsGyroid: s.topology == "gyroid",
            selected: selectedRegion,
            name: { [weak self] r in self?.displayName(r) ?? "Face \(r)" },
            removable: { [mainPageLoads] r in mainPageLoads.canRemove(r) },
            inherited: { [mainPageLoads] r in mainPageLoads.entry(r)?.role == .pressed })
    }

    public var readiness: FlexibleReadiness { FlexibleReadiness.evaluate(readinessInputs) }
}
