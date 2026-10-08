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
    public enum Kind: Equatable, Sendable { case shapeOnly, squeezeGroups, pinch }
    public let kind: Kind
    /// The Export step's ONE line ("Not sent: …").
    public let line: String
    /// Behind its (i).
    public let why: String
    /// 1–3 buttons (none when nothing core can run is at hand).
    public let fixes: [FlexibleCoreFix]

    public init(kind: Kind, line: String, why: String, fixes: [FlexibleCoreFix]) {
        self.kind = kind; self.line = line; self.why = why; self.fixes = fixes
    }

    /// The rule's order: a calibrate-first filament first (any send would be refused), then
    /// several squeeze groups, then a pinch (the encoder's order).
    public static func kind(calibrateFirst: Bool, groups: Int, pinches: Int) -> Kind? {
        if calibrateFirst { return .shapeOnly }
        if groups > 1 { return .squeezeGroups }
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
        }
    }

    /// What core CAN run instead, 1–3 buttons: each group alone (one end of any pinch inside it
    /// resting), or — one group — each end of the pinch resting. Only a set that leaves no pinch
    /// and at least one pressed face is offered.
    public static func sends(groups: [FlexibleSqueezeGroup], pinches: [(a: Int, b: Int)],
                             name: (Int) -> String) -> [FlexibleCoreFix] {
        let pressed = groups.flatMap(\.regions)
        func unique(_ xs: [Int]) -> [Int] { var seen = Set<Int>(); return xs.filter { seen.insert($0).inserted } }
        func noPinchLeft(_ rest: Set<Int>) -> Bool { pinches.allSatisfy { rest.contains($0.a) || rest.contains($0.b) } }
        func names(_ rs: [Int]) -> String { rs.map(name).joined(separator: ", ") }
        var out: [FlexibleCoreFix] = []
        if groups.count > 1 {
            for g in groups {
                let inside = Set(g.regions)
                let ends = unique(pinches.filter { inside.contains($0.a) && inside.contains($0.b) }.map(\.b))
                let rest = unique(pressed.filter { !inside.contains($0) } + ends)
                guard noPinchLeft(Set(rest)), rest.count < pressed.count else { continue }
                let only = "Group \(g.number) only"
                let scope = ends.isEmpty ? only : "\(only), \(names(ends)) resting"
                out.append(.send(resting: rest, title: "Send \(scope)", scope: scope))
                if out.count == 3 { break }
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
        FlexibleCoreHold.kind(calibrateFirst: material?.noPrediction != nil, groups: sentSqueezeGroups.count, pinches: pinches.count)
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
            return FlexibleCoreHold(kind: .squeezeGroups, line: FlexibleCoreRun.notSentLine(.squeezeGroups),
                                    why: FlexibleJob.EncodeError.squeezeGroups.description,
                                    fixes: FlexibleCoreHold.sends(groups: sentSqueezeGroups, pinches: pinches, name: { self.displayName($0) }))
        case .pinch:
            let p = pinches
            let line = p.count == 1
                ? "Not sent: core can\u{2019}t press \(displayName(p[0].a)) and \(displayName(p[0].b)) at once"
                : FlexibleCoreRun.notSentLine(.pinch)
            return FlexibleCoreHold(kind: .pinch, line: line, why: FlexibleJob.EncodeError.pinch.description,
                                    fixes: FlexibleCoreHold.sends(groups: sentSqueezeGroups, pinches: p, name: { self.displayName($0) }))
        }
    }
}
