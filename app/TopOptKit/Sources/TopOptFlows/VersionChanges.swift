// VersionChanges.swift — what changed between two versions, in his words, and the automatic name
// (approved Library mockup 2026-10-25, DATA-MODEL.md "Naming rule").
//
// The rule: `Part · v<n> · biggest change · next change`, then "+ n more". The order is the rank
// below: goal or stage, loads, anchors, Keep Clear and Protect, design box, material, plastic,
// resolution. A group is named by HIS name for it, or by how many faces it has — never by face
// number (he doesn't see face ids in the app).
//
// Groups are matched between the two versions by id first (a draft is a copy, so its groups keep
// their ids), then by name, then by the same faces — so two separately set-up copies of the same
// part still compare group to group instead of "everything removed, everything added".

import Foundation

public struct VersionChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, changed, removed }
    /// The naming rule's order: a lower rank is a bigger change.
    public enum Rank: Int, Codable, Sendable, Comparable {
        case goal, load, anchor, keepProtect, designBox, material, plastic, resolution, other
        public static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
    }
    public var kind: Kind
    public var rank: Rank
    /// The line a card shows: "Resolution 64 → 128".
    public var text: String
    /// The short form the automatic name uses: "res 128".
    public var phrase: String

    public init(_ kind: Kind, _ rank: Rank, _ text: String, phrase: String? = nil) {
        self.kind = kind
        self.rank = rank
        self.text = text
        self.phrase = phrase ?? text
    }
}

public enum VersionChanges {

    /// Every difference from `a` (the parent) to `b`, biggest first.
    public static func between(_ a: ProjectSnapshot, _ b: ProjectSnapshot) -> [VersionChange] {
        var out: [VersionChange] = []

        // goal and stage
        let minA = a.minimizePlastic ?? true, minB = b.minimizePlastic ?? true
        if minA != minB {
            let goal = minB ? "Minimize plastic" : "Strengthen"
            out.append(.init(.changed, .goal, "Goal: \(goal)", phrase: goal))
        }
        let stageA = stage(a.lattice), stageB = stage(b.lattice)
        if stageA != stageB {
            out.append(stageB.map { .init(.added, .goal, "Lattice: \($0)", phrase: "\($0) lattice") }
                       ?? .init(.removed, .goal, "No lattice"))
        } else if a.lattice != b.lattice, stageB != nil {
            out.append(.init(.changed, .goal, "\(stageB!) lattice settings"))
        }

        // groups: loads, anchors, Keep Clear, Protect
        out += groupChanges(a, b)
        if a.force.gravity != b.force.gravity { out.append(.init(.changed, .load, "Gravity direction")) }
        if a.force.faceProtectDepthMM != b.force.faceProtectDepthMM {
            out.append(.init(.changed, .keepProtect,
                             "Protect depth \(num(a.force.faceProtectDepthMM)) → \(num(b.force.faceProtectDepthMM)) mm"))
        }

        // design box and face edits
        if (a.designBox ?? DesignBoxModel()) != (b.designBox ?? DesignBoxModel()) {
            out.append(.init(.changed, .designBox, "Design box"))
        }
        if (a.faceRegions ?? FaceRegionModel()) != (b.faceRegions ?? FaceRegionModel()) {
            out.append(.init(.changed, .designBox, "Faces edited"))
        }

        // material, process, plastic
        if a.material != b.material {
            out.append(.init(.changed, .material, "Material \(a.material) → \(b.material)", phrase: b.material))
        }
        if a.process != b.process {
            out.append(.init(.changed, .material, "Process \(a.process.rawValue.uppercased()) → \(b.process.rawValue.uppercased())"))
        }
        if (a.printParams ?? .fdmDefault) != (b.printParams ?? .fdmDefault) {
            out.append(.init(.changed, .plastic, "Print settings"))
        }

        // resolution, then the rest
        let resA = (a.quality ?? .fast).resolution, resB = (b.quality ?? .fast).resolution
        if resA != resB { out.append(.init(.changed, .resolution, "Resolution \(resA) → \(resB)", phrase: "res \(resB)")) }
        if (a.projectCADFaces ?? true) != (b.projectCADFaces ?? true) {
            out.append(.init(.changed, .other, (b.projectCADFaces ?? true) ? "CAD faces on" : "CAD faces off"))
        }

        // stable: the rank first, then the order found
        return out.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
    }

    /// The automatic name. A first version is "first run · res 64"; the same settings on a newer
    /// engine are "engine update · same settings".
    public static func autoName(part: String, number: Int, changes: [VersionChange], resolution: Int,
                                engineUpdated: Bool = false) -> String {
        var bits: [String]
        if changes.isEmpty {
            bits = number <= 1 ? ["first run", "res \(resolution)"]
                : engineUpdated ? ["engine update", "same settings"] : ["same settings"]
        } else {
            bits = changes.prefix(2).map(\.phrase)
            if changes.count > 2 { bits.append("+\(changes.count - 2) more") }
        }
        return ([part, "v\(number)"] + bits).joined(separator: " · ")
    }

    // MARK: - groups

    private struct Role: Equatable {
        var kind: GroupKind
        var keepClear: Bool
        var protect: Bool
    }

    private static func role(_ g: SelectionGroup, _ f: ForceModel) -> Role {
        Role(kind: f.kind(for: g.id), keepClear: f.keepClearIsOn(g.id, autoDefault: false), protect: f.isProtected(g.id))
    }

    /// His name for a group, or how many faces it has. Auto names ("Group A") are not his.
    private static func label(_ g: SelectionGroup) -> String {
        if g.name.range(of: #"^Group [A-Z]+$"#, options: .regularExpression) == nil,
           !g.name.trimmingCharacters(in: .whitespaces).isEmpty { return g.name }
        let n = g.faces.count + g.regionIDs.count
        return n == 1 ? "1 face" : "\(n) faces"
    }

    private static func isAuto(_ g: SelectionGroup) -> Bool {
        g.name.range(of: #"^Group [A-Z]+$"#, options: .regularExpression) != nil
    }

    /// Pair the parent's groups with the child's: by id, then by name, then by the same faces.
    private static func pair(_ a: [SelectionGroup], _ b: [SelectionGroup]) -> (pairs: [(SelectionGroup, SelectionGroup)], gone: [SelectionGroup], new: [SelectionGroup]) {
        var left = a, right = b, pairs: [(SelectionGroup, SelectionGroup)] = []
        for match in [{ (x: SelectionGroup, y: SelectionGroup) in x.id == y.id },
                      { (x: SelectionGroup, y: SelectionGroup) in x.name == y.name },
                      { (x: SelectionGroup, y: SelectionGroup) in Set(x.faces) == Set(y.faces) && x.regionIDs == y.regionIDs }] {
            for x in left {
                guard let j = right.firstIndex(where: { match(x, $0) }) else { continue }
                pairs.append((x, right.remove(at: j)))
                left.removeAll { $0.id == x.id }
            }
        }
        return (pairs, left, right)
    }

    private static func roleLines(_ r: Role, on g: SelectionGroup, added: Bool) -> [VersionChange] {
        let l = label(g), k: VersionChange.Kind = added ? .added : .removed, no = added ? "" : "No "
        var out: [VersionChange] = []
        switch r.kind {
        case .anchor: out.append(.init(k, .anchor, "\(no)\(added ? "Anchor" : "anchor") on \(l)"))
        case .load: out.append(.init(k, .load, "\(no)\(added ? "Load" : "load") on \(l)"))
        default: break
        }
        if r.keepClear { out.append(.init(k, .keepProtect, "\(no)Keep Clear on \(l)")) }
        if r.protect { out.append(.init(k, .keepProtect, "\(no)Protect on \(l)")) }
        return out
    }

    private static func groupChanges(_ a: ProjectSnapshot, _ b: ProjectSnapshot) -> [VersionChange] {
        let (pairs, gone, new) = pair(a.selection.groups, b.selection.groups)
        var out: [VersionChange] = []
        for g in gone { out += roleLines(role(g, a.force), on: g, added: false) }
        for g in new { out += roleLines(role(g, b.force), on: g, added: true) }
        let unit = b.force.unit
        for (x, y) in pairs {
            let rx = role(x, a.force), ry = role(y, b.force)
            let named = isAuto(y) ? "" : " on \(y.name)"
            switch (rx.kind, ry.kind) {
            case let (.load(dx, wx), .load(dy, wy)):
                if wx != wy { out.append(.init(.changed, .load, "Load\(named) \(weight(wx, unit)) → \(weight(wy, unit)) \(unit.label)")) }
                if dx != dy { out.append(.init(.changed, .load, "Load\(named): \(dy.title)")) }
            case (.anchor, .anchor): break
            default:
                if rx.kind != ry.kind {
                    out += roleLines(Role(kind: rx.kind, keepClear: false, protect: false), on: x, added: false)
                    out += roleLines(Role(kind: ry.kind, keepClear: false, protect: false), on: y, added: true)
                }
            }
            if rx.keepClear != ry.keepClear { out.append(.init(ry.keepClear ? .added : .removed, .keepProtect, "\(ry.keepClear ? "" : "No ")Keep Clear on \(label(y))")) }
            if rx.protect != ry.protect { out.append(.init(ry.protect ? .added : .removed, .keepProtect, "\(ry.protect ? "" : "No ")Protect on \(label(y))")) }
            if Set(x.faces) != Set(y.faces) || x.regionIDs != y.regionIDs, rx.kind == ry.kind {
                let what = isAuto(y) ? roleWord(ry) : y.name
                let nx = x.faces.count + x.regionIDs.count, ny = y.faces.count + y.regionIDs.count
                out.append(.init(.changed, rank(ry), nx == ny ? "\(what) faces changed" : "\(what) \(nx) → \(ny) faces"))
            }
        }
        return out
    }

    private static func roleWord(_ r: Role) -> String {
        switch r.kind {
        case .anchor: return "Anchor"
        case .load: return "Load"
        default: return r.keepClear ? "Keep Clear" : r.protect ? "Protect" : "Group"
        }
    }

    private static func rank(_ r: Role) -> VersionChange.Rank {
        switch r.kind {
        case .anchor: return .anchor
        case .load: return .load
        default: return .keepProtect
        }
    }

    // MARK: - words

    private static func stage(_ l: LatticeSettings?) -> String? {
        guard let l else { return nil }
        if l.flexible != nil { return "Flexible" }
        return l.enabled ? (l.stageMode?.title ?? "Lattice") : nil
    }

    private static func weight(_ kg: Double, _ unit: WeightUnit) -> String {
        num(unit == .kg ? kg : kg * ForceModel.kgToLb)
    }

    /// 51 → "51", 3.5 → "3.5", 112.43 → "112.4".
    private static func num(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}
