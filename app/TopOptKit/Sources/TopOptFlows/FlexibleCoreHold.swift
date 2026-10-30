// FlexibleCoreHold — what core cannot run as the page is set up, known BEFORE the tap (task
// 2026-09-29-flexible-screens, round 4 batch C2 verification).
//
// ★ THE PILL NEVER PROMISES WHAT CORE WILL REFUSE. C2's big button read the green "Lattice ·
// Ready" on his own project as saved (faces 3 and 5 pinch the pad), on his img-4 setup (two
// squeeze groups) and on a calibrate-first filament (TPU 95A, img 1) — and a tap ended on "Not
// sent" / "Core refused it" with no way on. The app knows each case before the tap: several
// squeeze groups and a pinch are the app's preview only (core designs one squeeze, one profile
// per stack — core brief #1, #2, #6), and a calibrate-first filament is refused by core from the
// SAME catalogue entry the app reads (`material.noPrediction`: core's code and sentence).
// ★ SO: the lattice preview is still built and shown (a pinch builds — D2; a calibrate-first
// filament builds its shape-only lattice — the maintainer's answer), but the pill is a PREVIEW
// (not the Ready green) that says why in one line, and its tap opens the Export step on 1–3 fix
// buttons (his rule: "1-3 fix buttons"):
//   * a pinch: [Send with Face 5 resting] [Send with Face 3 resting] — in the JOB only; his
//     settings keep the pinch he asked for;
//   * squeeze groups: [Send Group 1 only] [Send Group 2 only] (a group with a pinch inside also
//     rests one end of it: "Send Group 2 only, Face 5 resting");
//   * a calibrate-first filament: [Use varioShore TPU] — the filament with squish data (his
//     settings change; the lattice rebuilds and Ready comes back).

import Foundation
import TopOptKit

/// One button of the Export step when core can't take the job as it stands.
public enum FlexibleCoreFix: Hashable, Sendable {
    /// Send the job with these pressed faces RESTING — in the job only. `scope` is what core's
    /// answer line says it designed ("Group 1 only", "Face 5 resting").
    case send(resting: [Int], title: String, scope: String)
    /// Use the filament with squish data (his settings change; the lattice rebuilds).
    case useFilament(id: String, name: String)

    /// The button's words.
    public var title: String {
        switch self {
        case .send(_, let t, _): return t
        case .useFilament(_, let n): return "Use \(FlexibleRowCopy.shortName(n))"
        }
    }

    /// The faces the job rests (none for a filament).
    public var resting: [Int] {
        if case .send(let r, _, _) = self { return r }
        return []
    }

    public var scope: String? {
        if case .send(_, _, let s) = self { return s }
        return nil
    }

    /// The button's test id.
    public var id: String {
        switch self {
        case .send(let r, _, _): return "send-" + r.map(String.init).joined(separator: "-")
        case .useFilament(let id, _): return "filament-\(id)"
        }
    }
}

/// Why the job Settings describes is not sent as it stands, and what can be sent instead.
public struct FlexibleCoreHold: Equatable, Sendable {
    /// ★ ROUND 7, M1 (5): `edgesBeside` — an edges/corners group beside face groups (the reviewer's ruling 4): core designs
    /// one squeeze group per job and takes no edge press yet, so the export makes ONE group, said before anything is sent.
    public enum Kind: Equatable, Sendable { case shapeOnly, squeezeGroups, pinch, edgesBeside }
    public let kind: Kind
    /// The Export step's ONE line ("Not sent: …").
    public let line: String
    /// Behind its (i).
    public let why: String
    /// 1–3 buttons (none when nothing core can run is at hand).
    public let fixes: [FlexibleCoreFix]
    /// ★ M1 (5): a second line under the step's line, while an edges group sits beside face groups ("Edges and faces go in
    /// separate exports for now.") — never a group dropped without a word. nil otherwise.
    public let note: String?

    public init(kind: Kind, line: String, why: String, fixes: [FlexibleCoreFix], note: String? = nil) {
        self.kind = kind; self.line = line; self.why = why; self.fixes = fixes; self.note = note
    }

    /// Test control only (M1): today's rule — an edges group that core does not take yet is not counted (no hold: the face
    /// group is sent and the edges group dropped without a word).
    nonisolated(unsafe) static var controlEdgesSilentlyDropped = false

    /// The rule's order: a calibrate-first filament first (any send would be refused), then
    /// several squeeze groups, then a pinch (the encoder's order).
    /// ★ M1 (5): `edgesBeside` — an edges group core does not take yet sits beside the face groups sent; after several face
    /// groups (their hold already makes one group per export), before a pinch (its sends are made one group's).
    public static func kind(calibrateFirst: Bool, groups: Int, pinches: Int, edgesBeside: Bool = false) -> Kind? {
        if calibrateFirst { return .shapeOnly }
        if groups > 1 { return .squeezeGroups }
        if edgesBeside, !controlEdgesSilentlyDropped { return .edgesBeside }
        if pinches > 0 { return .pinch }
        return nil
    }

    /// The pill's ONE line: the preview is there, core can't take it as it stands. A
    /// calibrate-first filament keeps his label ("TPU 95A: shape only — no squish predicted").
    public static func pill(_ k: Kind, shapeOnlyLabel: String?) -> String {
        switch k {
        case .shapeOnly: return shapeOnlyLabel ?? "Shape only \u{2014} no squish predicted"
        case .squeezeGroups: return "Preview \u{00B7} core runs one group at a time"
        case .pinch: return "Preview \u{00B7} core can\u{2019}t pinch yet"
        case .edgesBeside: return FlexibleRowCopy.edgesBesidePill   // ★ M1 (5)
        }
    }

    /// ★ RED CONTROL only (U21 batch R): the sends capped at three — a fourth group (three face groups and an edges group) unsendable.
    nonisolated(unsafe) static var controlSendsCapAtThree = false

    /// ★ U21 batch R (the reviewer's ruling E(1) of 2026-10-21, E2 Q2: "one [More…] listing every group, one per row; no fourth
    /// fixed button"): what the Export step and the card show of the sends — up to `fixedButtons` as buttons; past that two buttons
    /// and [More…], whose menu lists EVERY send, one per row.
    public enum Slot: Equatable, Sendable {
        case send(FlexibleCoreFix)
        case more([FlexibleCoreFix])
    }
    /// His "1–3 fix buttons".
    public static let fixedButtons = 3
    public static func slots(_ fixes: [FlexibleCoreFix]) -> [Slot] {
        guard fixes.count > fixedButtons else { return fixes.map { .send($0) } }
        return fixes.prefix(fixedButtons - 1).map { .send($0) } + [.more(fixes)]
    }

    /// What core CAN run instead, 1–3 buttons (★ U21 batch R: any number — `slots` shows them): each group alone (one end of any pinch inside it
    /// resting), or — one group — each end of the pinch resting. Only a set that leaves no pinch
    /// and at least one pressed face is offered.
    /// ★ R7-E2: `pressMarker` — a press IN THE JOB by its first region (nil: not in it). A send that leaves a group out lists its
    /// presses' markers among the resting regions: the job then leaves those presses out (a press is never a resting entry).
    public static func sends(groups: [FlexibleSqueezeGroup], pinches: [(a: Int, b: Int)],
                             name: (Int) -> String, pressMarker: ((UUID) -> Int?)? = nil) -> [FlexibleCoreFix] {
        let pressed = groups.flatMap(\.regions)
        func unique(_ xs: [Int]) -> [Int] { var seen = Set<Int>(); return xs.filter { seen.insert($0).inserted } }
        func noPinchLeft(_ rest: Set<Int>) -> Bool { pinches.allSatisfy { rest.contains($0.a) || rest.contains($0.b) } }
        // ★ ROUND 7 (M2): a face's lattice sections read once, by the face ("Face 2 resting", never "Face 2 · lattice B, …")
        func names(_ rs: [Int]) -> String {
            var seen = Set<String>(), out: [String] = []
            for n in rs.map(name) {
                let face = n.components(separatedBy: " \u{00B7} lattice").first ?? n
                if seen.insert(face).inserted { out.append(face) }
            }
            return out.joined(separator: ", ")
        }
        var out: [FlexibleCoreFix] = []
        if groups.count > 1 {
            for g in groups {
                let inside = Set(g.regions)
                let ends = unique(pinches.filter { inside.contains($0.a) && inside.contains($0.b) }.map(\.b))
                // ★ R7-E2: the other groups' presses in the job are left out by their markers (first regions)
                let outPresses = groups.filter { $0.id != g.id }.flatMap(\.presses).compactMap { pressMarker?($0) }
                let rest = unique(pressed.filter { !inside.contains($0) } + ends + outPresses)
                let restSet = Set(rest)
                let loadedLeft = pressed.contains { !restSet.contains($0) } || g.presses.contains { pressMarker?($0) != nil }
                guard noPinchLeft(restSet), loadedLeft else { continue }
                let only = "Group \(g.number) only"
                let scope = ends.isEmpty ? only : "\(only), \(names(ends)) resting"
                out.append(.send(resting: rest, title: "Send \(scope)", scope: scope))
                // ★ U21 batch R (the reviewer's ruling E(1), E2 Q2): every group can be sent — past three the buttons show two and
                // [More…] (`slots`). RED CONTROL `controlSendsCapAtThree`: the cap at three (a fourth group had no button).
                if Self.controlSendsCapAtThree, out.count == 3 { break }
            }
        } else if !pinches.isEmpty {
            for end in [{ (p: (a: Int, b: Int)) in p.b }, { (p: (a: Int, b: Int)) in p.a }] {
                let rest = unique(pinches.map(end))
                guard noPinchLeft(Set(rest)), rest.count < pressed.count else { continue }
                let scope = "\(names(rest)) resting"
                let f = FlexibleCoreFix.send(resting: rest, title: "Send with \(scope)", scope: scope)
                if !out.contains(f) { out.append(f) }
            }
        }
        return out
    }
}

extension FlexibleStageModel {

    /// What the pill reads (cheap: the filament, the groups, core's stack conflicts).
    /// ★ AP1: the groups with something SENT (a press alone in a group is not core's to run yet).
    public var coreHoldKind: FlexibleCoreHold.Kind? {
        // ★ R7-E2 RED CONTROL (FlexibleR7E2Tests): the hold before E2 — a sent press's group not counted
        if Self.controlHoldIgnoresPresses {
            return FlexibleCoreHold.kind(calibrateFirst: material?.noPrediction != nil,
                                         groups: FlexibleSqueezeGroups.groups(settings, sent: []).count, pinches: pinches.count)
        }
        return FlexibleCoreHold.kind(calibrateFirst: material?.noPrediction != nil, groups: sentSqueezeGroups.count, pinches: pinches.count,
                                     edgesBeside: !unsentEdgeGroups.isEmpty && !sentSqueezeGroups.isEmpty)
    }

    /// ★ ROUND 7, M1 (5): the edges/corners groups with no press in the job (since R7-E2: each kept out by its own gate reason) — never
    /// dropped from an export without a word.
    public var unsentEdgeGroups: [FlexibleSqueezeGroup] {
        let sent = Set(sentSqueezeGroups.map(\.id))
        return squeezeGroups.filter { $0.kind == .edges && !sent.contains($0.id) }
    }

    /// The Export step's hold, in full (read on the tap, never per body pass).
    public var coreHold: FlexibleCoreHold? {
        guard let k = coreHoldKind else { return nil }
        switch k {
        case .shapeOnly:
            let name = FlexibleRowCopy.shortName(material?.displayName ?? settings.materialID ?? "This filament")
            let why = material?.noPrediction.map { "\($0.reason) (\($0.code))" } ?? "\(name) has no lattice squish data."
            let with = catalogue.first { $0.noPrediction == nil }
            return FlexibleCoreHold(kind: .shapeOnly, line: "Not sent: \(name) has no squish data yet", why: why,
                                    fixes: with.map { [.useFilament(id: $0.id, name: $0.displayName)] } ?? [])
        case .squeezeGroups:
            // ★ M1 (5): an edges group beside them is SAID (each export makes one face group; the edges wait for core)
            let edges = FlexibleCoreHold.controlEdgesSilentlyDropped ? [] : unsentEdgeGroups   // (the red control drops them unsaid)
            return FlexibleCoreHold(kind: .squeezeGroups,
                                    line: edges.isEmpty ? FlexibleCoreRun.notSentLine(.squeezeGroups) : FlexibleRowCopy.exportMakesOneEach,
                                    why: FlexibleJob.EncodeError.squeezeGroups.description + edgesWhy(edges),
                                    fixes: FlexibleCoreHold.sends(groups: sentSqueezeGroups, pinches: pinches, name: { self.displayName($0) },
                                                                  pressMarker: { self.sentPressMarker($0) }),   // ★ R7-E2
                                    note: edges.isEmpty ? nil : FlexibleRowCopy.edgesExportSeparately)
        case .edgesBeside:
            // ★ M1 (5, the reviewer's ruling 4): ONE face group beside the edges group(s) — "This export makes Group 1 only."
            // and "Edges and faces go in separate exports for now.", before anything is sent; his name for the group
            let g = sentSqueezeGroups[0]
            // ★ M1 VERIFY (his answer: "Group names in squish are JUST squish groups. NOT lattice groups."): the squeeze group's
            // NUMBER, as every other [Send Group N only] button — never his Squish-page name on the main page's Export step
            let name = exportName(g)
            let p = pinches
            let fixes: [FlexibleCoreFix] = p.isEmpty
                ? [.send(resting: [], title: "Send \(name) only", scope: "\(name) only")]
                : FlexibleCoreHold.sends(groups: [g], pinches: p, name: { self.displayName($0) }).map { f in
                    guard case .send(let rest, _, let scope) = f else { return f }
                    return .send(resting: rest, title: "Send \(name) only, \(scope)", scope: "\(name) only, \(scope)")
                }
            return FlexibleCoreHold(kind: .edgesBeside, line: FlexibleRowCopy.exportMakesOnly(name),
                                    why: "Core designs one squeeze group per job." + edgesWhy(unsentEdgeGroups),
                                    fixes: fixes, note: FlexibleRowCopy.edgesExportSeparately)
        case .pinch:
            let p = pinches
            let line = p.count == 1
                ? "Not sent: core can\u{2019}t press \(displayName(p[0].a)) and \(displayName(p[0].b)) at once"
                : FlexibleCoreRun.notSentLine(.pinch)
            return FlexibleCoreHold(kind: .pinch, line: line, why: FlexibleJob.EncodeError.pinch.description,
                                    fixes: FlexibleCoreHold.sends(groups: sentSqueezeGroups, pinches: p, name: { self.displayName($0) },
                                                                  pressMarker: { self.sentPressMarker($0) }))
        }
    }

    /// ★ M1 VERIFY: a squeeze group as the Export step names it — "Group N" (RED CONTROL `controlSquishNameInExport`: his name).
    func exportName(_ g: FlexibleSqueezeGroup) -> String {
        FlexibleCoreHold.controlSquishNameInExport ? groupName(g) : FlexibleRowCopy.groupName(g.number)
    }

    /// ★ M1 (5): behind the (i) — the edges groups this export leaves out, by name, and why.
    func edgesWhy(_ edges: [FlexibleSqueezeGroup]) -> String {
        guard !edges.isEmpty else { return "" }
        let names = edges.map { exportName($0) }
        let who = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        // ★ R7-E2 FIX (the verify: core does take presses since E2): the first kept-out press's own reason; "core does not take …
        // yet" only when core's side is closed
        let out = edges.lazy.flatMap(\.presses).compactMap { self.pressSupport[$0] }.first { !$0.inJob && $0.reason != .coreSupport }
        let why = out?.line.flatMap { $0.isEmpty ? nil : $0 } ?? "core does not take edge or corner presses yet"
        return " \(who) (edges and corners) \(names.count == 1 ? "is" : "are") not in this export: \(why)."
    }
}
