// RedesignToStrengthen.swift — "Redesign to strengthen" on the Mac worker
// (Flexible PR #362 H56, overnight plan 2026-10-25).
//
// TO-core item 50 (62e909b6): a job carrying `loads.redesign: "strengthen"` with a
// `design_box` (and `loads.minimize_plastic: false`) rebuilds the part inside the box
// as three versions, each verified on its exported geometry, and report.json carries a
// top-level `strengthen` block. Items 41 / 47 / 42-B add a per-variant `bodies` block:
// bridges that hold themselves (`bridges`, `bridge_holds[]`) and the rung rejected for
// letting an anchored piece go (`rejection_reason: "anchored piece detached"`).
//
// Everything here is a pure value type — the send's rule, the report's blocks, every
// user-facing line — so it is headlessly assertable. One SwiftUI view renders the cards
// on the results screen and on the failure sheet alike.
//
// ★ NO FACE NUMBERS reach a line (the owner never sees face ids): `lost_anchor_face_ids`
// and `cap.face_id` are parsed and never printed, and a core note is passed through
// `StrengthenText.plain`, which replaces any "face N" with "a face".

import Foundation
import SwiftUI
import TopOptDesign
import TopOptKit

// MARK: - the send

/// Where "Redesign to strengthen" may run, and the one rule that puts it on the wire.
public enum StrengthenRoute {
    /// The value core reads at `loads.redesign`.
    public static let redesignValue = "strengthen"
    /// THE ONE LINE an on-device run shows for the disabled strengthen choice.
    public static let onDeviceLine = "Runs on your Mac"

    /// The strengthen redesign runs only on the Mac worker (core's search + verify solves).
    public static func canChoose(workerSelected: Bool) -> Bool { workerSelected }

    /// The line beside the strengthen choice: nil on the worker, the one line on device.
    public static func line(workerSelected: Bool) -> String? {
        canChoose(workerSelected: workerSelected) ? nil : onDeviceLine
    }

    /// The toast when the strengthen choice is tapped on device.
    public static var onDeviceToast: String { LadderMode.growth.title + ": " + onDeviceLine }

    /// `loads.redesign` for a request the WORKER will run: "strengthen" for an Optimize run
    /// in the strengthen mode (Minimize plastic off) that carries a design box (core rebuilds
    /// the part inside it and refuses the key without one); "" otherwise, so the job is
    /// byte-identical to one written before this key existed.
    /// THE ONE LINE the app shows when "Redesign to strengthen" would go to the worker with no design box.
    public static let noBoxLine = "Draw a design box first"

    /// Why the Mac worker may not start this request, or nil. Core rebuilds the part INSIDE the design box and
    /// refuses `redesign` without one, so a strengthen run with no box used to ship no key and silently run the
    /// growth job instead (`redesign(for:)` below). Now it is refused in the app, in one line, before the send. On
    /// device the strengthen redesign is not offered (`line(workerSelected:)`), so the device run is unchanged.
    public static func refusal(for request: RunRequest, workerSelected: Bool) -> String? {
        workerSelected && request.jobMode == "minimize_plastic" && !request.minimizePlastic && request.designBox == nil ? noBoxLine : nil   // Flexible (PR #362) H56m: redesign to strengthen (overnight plan 2026-10-25) — no design box: refused, never the growth job in its place
    }

    public static func redesign(for request: RunRequest) -> String {
        request.jobMode == "minimize_plastic" && !request.minimizePlastic && request.designBox != nil
            ? redesignValue : ""
    }
}

extension RunRequest {
    /// The same request as the Mac worker runs it: `redesign` decided by `StrengthenRoute`.
    /// A COPY, like `withJobMode`, so a request already handed to a runner never changes.
    public func forWorker() -> RunRequest {
        var copy = self
        copy.redesign = StrengthenRoute.redesign(for: self)
        return copy
    }
}

// MARK: - the report's blocks

/// One bridge's hold-itself receipt (`bodies.bridge_holds[]`, TO-core item 42-B).
public struct BridgeHold: Equatable, Sendable {
    public let sizeMM: Double
    public let holdMargin: Double
    public let thickenings: Int
    public let held: Bool
}

/// A variant's `bodies` block (TO-core items 41 / 47 / 42-B).
public struct VariantBodies: Equatable, Sendable {
    public let exported: Int
    public let anchoredPiecesLost: Int
    /// Parsed, NEVER printed (the owner never sees face ids).
    public let lostAnchorFaceIDs: [Int]
    public let bridges: Int
    public let bridgeVoxels: Int
    public let bridgeHolds: [BridgeHold]

    public static func decode(_ b: [String: Any]?) -> VariantBodies? {
        guard let b else { return nil }
        let holds = (b["bridge_holds"] as? [[String: Any]] ?? []).map {
            BridgeHold(sizeMM: num($0["size_mm"]), holdMargin: num($0["hold_margin"]),
                       thickenings: int($0["thickenings"]), held: $0["held"] as? Bool ?? false)
        }
        return VariantBodies(exported: int(b["exported"]),
                             anchoredPiecesLost: int(b["anchored_pieces_lost"]),
                             lostAnchorFaceIDs: (b["lost_anchor_face_ids"] as? [Any] ?? []).map(int),
                             bridges: int(b["bridges"]), bridgeVoxels: int(b["bridge_voxels"]),
                             bridgeHolds: holds)
    }
}

/// The top-level `strengthen` block (TO-core item 50).
public struct StrengthenReport: Equatable, Sendable {
    /// Where the box filled solid peaks (`cap`). Its note names a face, so it is never parsed or printed: the line
    /// is built from `atAnchorFace` / `atLoadFace` (`StrengthenText.capLine`).
    public struct Cap: Equatable, Sendable {
        public let faceID: Int
        public let point: [Double]
        public let atAnchorFace: Bool
        public let atLoadFace: Bool
        public let note: String
    }
    /// One of the three versions (`versions[]`).
    public struct Version: Equatable, Sendable {
        public let version: Int
        public let stressCut: Double
        /// "verified" | "repaired" | "unreachable" | "merged"
        public let status: String
        public let volumeFraction: Double
        public let verifiedMargin: Double
        public let massGrams: Double
        public let massFractionOfOriginal: Double
        public let note: String
        /// The margin this version aimed for (`target_margin`): a refused version shows its best try against it.
        public var targetMargin: Double = 0
        /// ★ load scenarios (ruling 2026-10-26 12:46): this version's own `scenarios[]`; its margin is the worst one's.
        public var scenarios: [ScenarioResult] = []
    }
    public let asDrawnMargin: Double
    public let marginRequired: Double
    public let ceilingMargin: Double
    public let originalMassGrams: Double
    public let coarseResolution: Int
    public let cap: Cap?
    public let versions: [Version]
    /// ★ THE NEW LADDER (ruling 2026-10-26 13:12): the safety margin the versions were built for. nil = a report from the
    /// 25/50/75 % ladder, whose cards keep their old titles.
    public var safetyMargin: Double? = nil

    public static func decode(_ s: [String: Any]?) -> StrengthenReport? {
        guard let s else { return nil }
        let cap = (s["cap"] as? [String: Any]).map {
            Cap(faceID: int($0["face_id"]), point: ($0["point"] as? [Any] ?? []).map(num),
                atAnchorFace: $0["at_anchor_face"] as? Bool ?? false,
                atLoadFace: $0["at_load_face"] as? Bool ?? false,
                note: $0["note"] as? String ?? "")
        }
        let versions = (s["versions"] as? [[String: Any]] ?? []).map {
            Version(version: int($0["version"]), stressCut: num($0["stress_cut"]),
                    status: $0["status"] as? String ?? "", volumeFraction: num($0["volume_fraction"]),
                    verifiedMargin: num($0["verified_margin"]), massGrams: num($0["mass_grams"]),
                    massFractionOfOriginal: num($0["mass_fraction_of_original"]),
                    note: $0["note"] as? String ?? "", targetMargin: num($0["target_margin"]),
                    scenarios: ScenarioResult.parse($0))
        }
        return StrengthenReport(asDrawnMargin: num(s["as_drawn_margin"]),
                                marginRequired: num(s["margin_required"]),
                                ceilingMargin: num(s["ceiling_margin"]),
                                originalMassGrams: num(s["original_mass_grams"]),
                                coarseResolution: int(s["coarse_resolution"]),
                                cap: cap, versions: versions,
                                safetyMargin: (s["safety_margin"] as? NSNumber)?.doubleValue)
    }
}

/// The blocks of a worker's report.json the app reads by key: the strengthen block and
/// each evaluated variant's verdict + bodies (accepted `variants`, then `rejected_variants`).
public struct RunReportBlocks: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let volumeFraction: Double
        public let printedFraction: Double
        public let accepted: Bool
        public let rejectionReason: String
        public let bodies: VariantBodies?
        /// Places where the printed variant holds together only by an edge or a corner (`fragile_joints.count`;
        /// core's loose-piece fix, the reviewer's ruling 2026-10-26 03:39). Reported, never fixed.
        public var fragileJoints: Int = 0
    }
    public let strengthen: StrengthenReport?
    public let rows: [Row]
    /// ★ report.json's top-level `safety_margin` (ruling 2026-10-26 13:12): "Built for N% of your load". nil = not sent.
    public var safetyMargin: Double? = nil

    public static func decode(reportJSON: Data) -> RunReportBlocks? {
        guard let r = (try? JSONSerialization.jsonObject(with: reportJSON)) as? [String: Any] else { return nil }
        return decode(report: r)
    }

    public static func decode(report r: [String: Any]) -> RunReportBlocks {
        func rows(_ key: String, accepted: Bool) -> [Row] {
            (r[key] as? [[String: Any]] ?? []).map {
                Row(volumeFraction: num($0["volume_fraction"]),
                    printedFraction: num($0["printed_fraction"] ?? $0["volume_fraction"]),
                    accepted: $0["accepted"] as? Bool ?? accepted,
                    rejectionReason: $0["rejection_reason"] as? String ?? "",
                    bodies: VariantBodies.decode($0["bodies"] as? [String: Any]),
                    fragileJoints: int(($0["fragile_joints"] as? [String: Any])?["count"]))
            }
        }
        var strengthen = StrengthenReport.decode(r["strengthen"] as? [String: Any])
        let margin = (r["safety_margin"] as? NSNumber)?.doubleValue ?? strengthen?.safetyMargin
        if strengthen?.safetyMargin == nil { strengthen?.safetyMargin = margin }
        return RunReportBlocks(strengthen: strengthen,
                               rows: rows("variants", accepted: true) + rows("rejected_variants", accepted: false),
                               safetyMargin: margin)
    }
}

private func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

// MARK: - the words

/// One strengthen version's card.
public struct StrengthenCard: Equatable, Sendable {
    public let title: String
    public let status: String
    public let lines: [String]
    public let bridged: Bool
}

/// Every user-facing line the strengthen results show.
public enum StrengthenText {
    public static let bridgedBadge = "BRIDGED"
    /// TO-core item 47's rejection, in plain words (no face numbers).
    public static let anchoredLetGoLine = "This version let go of an anchored bolt hole"
    public static let anchoredDetachedReason = "anchored piece detached"

    public static func statusWord(_ status: String) -> String {
        switch status {
        case "verified": return "Verified"
        case "repaired": return "Repaired"
        case "unreachable": return "Unreachable"
        case "merged": return "Merged"
        default: return status.prefix(1).uppercased() + status.dropFirst()
        }
    }

    /// A core note with any face number replaced ("on face 12" → "on a face").
    public static func plain(_ note: String) -> String {
        note.replacingOccurrences(of: #"\b[Ff]aces? \d+(\s*(,|and)\s*\d+)*"#, with: "a face",
                                  options: .regularExpression)
    }

    static func percent(_ fraction: Double) -> String { String(format: "%.0f", fraction * 100) }

    /// The version whose variants[] line `v` reads. Core writes NO line for a "merged" version (run_job.cpp
    /// strengthen_versions: `continue` before append_rung; note "the same design as version N", N = this version − 1,
    /// and its own volume_fraction is only within 1 % of that line's). It is the design of the last earlier version
    /// that got a line (core's `prev_vf`: verified or repaired), so walk back over merged (and unreachable) versions.
    static func lineVersion(of v: StrengthenReport.Version, in s: StrengthenReport) -> StrengthenReport.Version {
        guard v.status == "merged" else { return v }
        return s.versions.last { $0.version < v.version && $0.status != "merged" && $0.status != "unreachable" } ?? v   // Flexible (PR #362) H56k: redesign to strengthen (overnight plan 2026-10-25) — the previous version's line (N = this version − 1, merged ones walked back)
    }

    /// The cards, one per version, in core's order.
    public static func cards(_ blocks: RunReportBlocks) -> [StrengthenCard] {
        guard let s = blocks.strengthen else { return [] }
        return s.versions.map { v in
            var lines: [String] = []
            if v.status == "unreachable", v.verifiedMargin > 0, v.targetMargin > 0 {
                lines.append(bestTryLine(v))
            } else if v.status == "unreachable" {
                lines.append(v.note.isEmpty ? "Unreachable in this design space" : plain(v.note))
            } else {
                lines.append("Margin " + String(format: "%.2f", v.verifiedMargin) + "×")
                lines.append(String(format: "%.1f", v.massGrams) + " g · "
                             + percent(v.massFractionOfOriginal) + " % of the original")
                if !v.note.isEmpty { lines.append(plain(v.note)) }
            }
            // ★ load scenarios: the card names its governing scenario ("Worst case: <name> · N×", after core's note) — a
            // best try names it in its own line instead — and an unheld one gets one line. Thin joints stay last.
            lines.append(contentsOf: ScenarioResult.lines(v.scenarios).filter { !(isBestTry(v) && $0.hasPrefix("Worst case")) })
            let own = lineVersion(of: v, in: s)   // Flexible (PR #362) H56k: redesign to strengthen (overnight plan 2026-10-25) — a merged version reads the line of the version it merged into
            let ownRow = blocks.rows.first { abs($0.volumeFraction - own.volumeFraction) < 1e-6 }
            let bridged = own.status != "unreachable" && (ownRow?.bodies.map(joined) ?? false)
            // ★ in pieces: accepted, with the flag and why (his ruling 2026-10-28)
            if own.status != "unreachable", let flag = piecesFlag(ownRow?.bodies) { lines.append(flag.title); lines += flag.lines }
            if own.status != "unreachable",
               let thin = blocks.rows.first(where: { abs($0.volumeFraction - own.volumeFraction) < 1e-6 })?.fragileJoints,
               thin > 0 {
                lines.append(thinJointsLine(thin))
            }
            return StrengthenCard(title: title(v, in: s),
                                  status: statusWord(v.status), lines: lines, bridged: bridged)
        }
    }

    /// A card's title. The new ladder (a report with `safety_margin`): "Version 1: just safe", then "Version N: +10%".
    /// A 25/50/75 % report keeps "Version N · M % less worst stress".
    static func title(_ v: StrengthenReport.Version, in s: StrengthenReport) -> String {
        guard s.safetyMargin != nil else { return "Version \(v.version) · " + percent(v.stressCut) + " % less worst stress" }
        return v.version <= 1 ? "Version \(v.version): just safe" : "Version \(v.version): +10%"
    }

    public static let capAnchorLine = "The strongest possible version is limited at an anchor"
    public static let capLoadLine = "The strongest possible version is limited at the load"

    /// Where the box filled solid peaks, in plain words — built from `cap.at_anchor_face` / `cap.at_load_face` ONLY.
    /// `cap.note` is never parsed (it names a face). Both true: the anchor's words, core's own precedence
    /// (run_job.cpp, the cap note). Neither: no line.
    public static func capLine(_ blocks: RunReportBlocks) -> String? {
        guard let cap = blocks.strengthen?.cap else { return nil }
        return cap.atAnchorFace ? capAnchorLine : cap.atLoadFace ? capLoadLine : nil   // Flexible (PR #362) H56l: redesign to strengthen (overnight plan 2026-10-25) — the cap's line from its flags, never its note
    }

    /// A version refused after real tries (the reviewer's ruling 2026-10-26 07:29, item 50 (c)): its best verified try
    /// against what it needed, on ONE line; a reason other than the margin (core's note: Keep Clear voxels, not accepted)
    /// rides on the same line, in plain words.
    static func isBestTry(_ v: StrengthenReport.Version) -> Bool {
        v.status == "unreachable" && v.verifiedMargin > 0 && v.targetMargin > 0
    }

    static func bestTryLine(_ v: StrengthenReport.Version) -> String {
        let line = "Best try " + String(format: "%.2f", v.verifiedMargin) + "×, needed "
            + String(format: "%.2f", v.targetMargin) + "×"
        let marginOnly = v.note.isEmpty || v.note.hasPrefix("verified ") || v.note.contains("missed the target")
        // ★ load scenarios (362, 2026-10-26): a refused try names the scenario that governed it
        let worst = v.scenarios.count >= 2 ? v.scenarios.first(where: { $0.governs }).map { " — worst: " + $0.name } ?? "" : ""
        return (marginOnly ? line : line + " — " + plain(v.note)) + worst
    }

    /// A version's thin joints (core's `fragile_joints.count`), in plain words. core's own note is never shown.
    public static func thinJointsLine(_ count: Int) -> String {
        "\(count) thin joint\(count == 1 ? "" : "s") (edge or corner only) — may be fragile to print"
    }
    public static let someThinJointsLine = "Some results have thin joints (edge or corner only) — may be fragile to print"

    /// The lines under the cards: the cap's line, then the run's rejection lines, then — on a run with no strengthen
    /// cards to carry it — one thin-joint line when an accepted result has any.
    public static func lines(_ blocks: RunReportBlocks) -> [String] {
        let thin = blocks.strengthen == nil && blocks.rows.contains { $0.accepted && $0.fragileJoints > 0 }
        return [capLine(blocks)].compactMap { $0 } + rejectionLines(blocks) + (thin ? [someThinJointsLine] : [])
    }

    /// The run's rejection lines in plain words (item 47), once each.
    public static func rejectionLines(_ blocks: RunReportBlocks) -> [String] {
        blocks.rows.contains { !$0.accepted && $0.rejectionReason == anchoredDetachedReason }
            ? [anchoredLetGoLine] : []
    }

    /// Whether the accepted variant printed at `printedFraction` was JOINED by bridges: it has some, every one held, and it
    /// exports as one body. (★ his iPad 2026-10-28: e40f618a's V1 had a bridge that did not hold and exported as 2 pieces,
    /// yet said "Two pieces were joined into one part" — this used to ask only `bridges > 0`.)
    public static func isBridged(printedFraction: Double, in blocks: RunReportBlocks) -> Bool {
        blocks.rows.first { $0.accepted && abs($0.printedFraction - printedFraction) < 1e-4 }?.bodies.map(joined) ?? false
    }
    static func joined(_ b: VariantBodies) -> Bool { b.bridges > 0 && b.exported <= 1 && b.bridgeHolds.allSatisfy(\.held) }

    // MARK: ★ a version that prints in pieces (his ruling 2026-10-28: "accepted with a flag")

    /// A version core exported as 2+ bodies: how many, and the size of each bridge that couldn't hold (so was left out).
    public struct PiecesFlag: Equatable, Sendable {
        public let pieces: Int
        public let droppedBridgesMM: [Double]
        /// "Prints in 2 pieces" (N when more).
        public var title: String { "Prints in \(pieces) pieces" }
        /// One line per bridge that didn't hold; with none, each piece stands on its own anchors.
        public var lines: [String] {
            droppedBridgesMM.isEmpty ? ["Each piece holds on its own anchors."]
                : droppedBridgesMM.map { "A \(Int($0.rounded())) mm bridge between them couldn’t hold its load, so it was left out." }
        }
    }
    static func piecesFlag(_ b: VariantBodies?) -> PiecesFlag? {
        guard let b, b.exported >= 2 else { return nil }
        return PiecesFlag(pieces: b.exported, droppedBridgesMM: b.bridgeHolds.filter { !$0.held }.map(\.sizeMM))
    }
    /// The flag for the accepted variant printed at `printedFraction`, or nil (one body).
    public static func piecesFlag(printedFraction: Double, in blocks: RunReportBlocks) -> PiecesFlag? {
        piecesFlag(blocks.rows.first { $0.accepted && abs($0.printedFraction - printedFraction) < 1e-4 }?.bodies)
    }
    /// The flag for a strengthen version's line (matched like the cards: by volume fraction).
    public static func piecesFlag(volumeFraction vf: Double, in blocks: RunReportBlocks) -> PiecesFlag? {
        piecesFlag(blocks.rows.first { abs($0.volumeFraction - vf) < 1e-6 }?.bodies)
    }
}

// MARK: - the view

/// The strengthen cards and the run's rejection lines (results screen + failure sheet).
/// Renders nothing for a report with neither.
public struct RunReportCardsView: View {
    let cards: [StrengthenCard]
    let lines: [String]

    public init(blocks: RunReportBlocks) {
        cards = StrengthenText.cards(blocks)
        lines = StrengthenText.lines(blocks)   // Flexible (PR #362) H56l: redesign to strengthen (overnight plan 2026-10-25) — the cap's line, then item 47's
    }

    public var body: some View {
        if !cards.isEmpty || !lines.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, c in card(c) }
                ForEach(lines, id: \.self) { l in
                    Text(l).dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                        .foregroundStyle(DS.Color.warning.color)
                }
            }
            .accessibilityIdentifier("strengthen-cards")
        }
    }

    private func card(_ c: StrengthenCard) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.s) {
                Text(c.title).dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textPrimary.color)
                Text(c.status).font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle((c.status == "Unreachable" ? DS.Color.textTertiary : DS.Color.okGreen).color)
                if c.bridged {
                    Text(StrengthenText.bridgedBadge).font(.system(size: 9, weight: .bold)).tracking(0.6)
                        .foregroundStyle(DS.Color.warning.color)
                }
            }
            ForEach(c.lines, id: \.self) { l in
                Text(l).dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.l)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Surface.bar.color)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
    }
}
