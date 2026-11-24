// LatticeFileRefusal — ★ notes25 (A5, his 11-23 evening, and 362's worker investigation): his cell lattice's print file
// stopped on the Mac after ~7 min and the iPad said only "The file could not be made" on the button's second line. The
// engine's own reason is in the job's lattice_file.json (`ok: false`, `code`, `why`, `detail`, and where: `findings_at`), which
// the worker serves even after a restart. It is read here, said in a centred pop-up in plain words naming only the problems
// that are there (his rule: errors are centred plain-English pop-ups), with "Show me" (the view turns to the spot and marks
// it on the part: a picture, never coordinates), "Change settings" (the setting the reason names) and "OK".
import Foundation
import SwiftUI
import simd
import TopOptDesign

/// Why the engine made no print file (lattice_file.json with `ok: false`).
public struct LatticeFileRefusal: Equatable, Sendable {
    public var code: String
    public var why: String
    public var detail: String
    /// Where (the part's own mm): each finding's place.
    public var findingsAt: [SIMD3<Double>]
    /// The print check's counts: places starting in mid-air, overhangs held at one end, bridges too long to span.
    public var midAir: Int
    public var oneEnded: Int
    public var longBridges: Int
    /// ★ notes25 (his 11-23 ~18:55: "I used "auto" on the lattices. So I shouldn't *need* to change any settings. The auto should
    /// adjust itself."): Auto has already adjusted the settings for the next press (the engine side is 362's, being designed:
    /// `auto_adjusted` and `adjusted` [{setting, from, to}] are read when the report carries them).
    public var autoAdjusted = false
    public struct Adjusted: Equatable, Sendable {
        public var setting: String
        public var from: String
        public var to: String
        public init(setting: String, from: String, to: String) { self.setting = setting; self.from = from; self.to = to }
    }
    public var adjusted: [Adjusted] = []

    public init(code: String, why: String, detail: String, findingsAt: [SIMD3<Double>], midAir: Int, oneEnded: Int,
                longBridges: Int, autoAdjusted: Bool = false, adjusted: [Adjusted] = []) {
        self.code = code; self.why = why; self.detail = detail; self.findingsAt = findingsAt
        self.midAir = midAir; self.oneEnded = oneEnded; self.longBridges = longBridges
        self.autoAdjusted = autoAdjusted; self.adjusted = adjusted
    }

    /// lattice_file.json read; nil when it is not one, or it made its file (`ok: true`).
    public static func parse(_ d: Data) -> LatticeFileRefusal? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], (o["ok"] as? Bool) == false else { return nil }
        let p = o["print_check"] as? [String: Any] ?? [:]
        func n(_ k: String) -> Int { (p[k] as? NSNumber)?.intValue ?? 0 }
        let at = (p["findings_at"] as? [[NSNumber]] ?? []).compactMap { v -> SIMD3<Double>? in
            v.count == 3 ? SIMD3(v[0].doubleValue, v[1].doubleValue, v[2].doubleValue) : nil
        }
        func said(_ v: Any?) -> String { v.map { "\($0)" } ?? "" }
        let adjusted = (o["adjusted"] as? [[String: Any]] ?? []).map {
            Adjusted(setting: said($0["setting"]), from: said($0["from"]), to: said($0["to"]))
        }
        return LatticeFileRefusal(code: o["code"] as? String ?? "", why: o["why"] as? String ?? "", detail: o["detail"] as? String ?? "",
                                  findingsAt: at, midAir: Swift.max(n("midair_starts"), n("mid_air")), oneEnded: n("one_ended"),
                                  longBridges: n("long_bridges"), autoAdjusted: (o["auto_adjusted"] as? Bool) ?? false,
                                  adjusted: adjusted)
    }

    /// ★ notes25: the pop-up, as data (its words and buttons) — the plain refusal, or (Auto adjusted it) his own wording.
    public struct PopUp: Equatable, Sendable {
        public enum Button: Equatable, Sendable { case latticeAgain, changeSettings, showMe, ok }
        public var title: String
        public var text: String
        /// In order; the first is the primary.
        public var buttons: [Button]
    }
    public static let latticeAgain = "Lattice again"
    /// His words (11-23 ~18:55) for a refusal Auto has already answered.
    public static let autoAdjustedText = "The app has already adjusted the settings for you; press Lattice to try again. Prefer to "
        + "set them yourself? Change settings."

    public var popUp: PopUp {
        let showMe: [PopUp.Button] = findingsAt.isEmpty ? [] : [.showMe]
        guard autoAdjusted else {
            return PopUp(title: LatticeMacMakeCopy.failedTitle, text: plain, buttons: showMe + [.changeSettings, .ok])
        }
        let list = adjusted.map { "\($0.setting) \($0.from) \u{2192} \($0.to)" }.joined(separator: ", ")
        return PopUp(title: LatticeMacMakeCopy.failedTitle,
                     text: Self.autoAdjustedText + (list.isEmpty ? "" : "\n\nAdjusted: " + list + "."),
                     buttons: [.latticeAgain, .changeSettings] + showMe)
    }

    /// ★ notes25 ("Change settings": "lead to the settings page, scrolling to and highlighting the field to change along with
    /// what to try"): where, which field, and what to try.
    public var settingToChange: SettingToChange.Ask {
        switch setting {
        case .latticeCells: return .init(page: .lattice, field: LatticeWizardSetting.cellSize.rawValue, tryText: "Try a larger cell")
        case .protectSkin: return .init(page: .topologySettings, field: TopologySetupRow.protectSkin.rawValue,
                                        tryText: "Protect the faces nearby")
        case .faces: return .init(page: .selections, field: "faces", tryText: "Pick its faces again")
        }
    }

    /// The reason in plain words, naming only the problems that are there (the print check's), then what fixes it; any other
    /// refusal in the engine's own plain sentence.
    public var plain: String {
        if code == "would_not_print" {
            func many(_ k: Int, _ one: String, _ more: String) -> String? { k == 0 ? nil : "\(k) \(k == 1 ? one : more)" }
            let found = [many(midAir, "place that would start printing in mid-air", "places that would start printing in mid-air"),
                         many(oneEnded, "overhang held at one end only", "overhangs held at one end only"),
                         many(longBridges, "bridge longer than a printer can span", "bridges longer than a printer can span")]
                .compactMap { $0 }
            if !found.isEmpty {
                let list = found.count == 1 ? found[0]
                    : found.dropLast().joined(separator: ", ") + " and " + found[found.count - 1]
                let it = midAir + oneEnded + longBridges == 1 ? "it" : "those places"
                return "The lattice has \(list), so no file was made. A larger cell or a Protect skin near \(it) usually fixes it."
            }
        }
        let w = why.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? LatticeMacMakeCopy.failedText(nil, onMac: true) : w
    }

    /// The setting "Change settings" opens.
    public enum Setting: Equatable, Sendable { case latticeCells, protectSkin, faces }
    public var setting: Setting {
        switch code {
        case "protect_faces_missing": return .protectSkin
        case "region_faces_missing": return .faces
        default: return .latticeCells
        }
    }

    /// The words of the pop-up's buttons (five at most each).
    public static let showMe = "Show me"
    public static let changeSettings = "Change settings"
    public static let ok = "OK"
}

/// ★ notes25: the spot "Show me" marks on the part (model space), until the next press or another version.
@MainActor
public final class LatticeFileSpot: ObservableObject {
    public static let shared = LatticeFileSpot()
    @Published public private(set) var spot: (version: UUID, at: SIMD3<Float>)?
    public init() {}
    func mark(_ at: SIMD3<Float>, version: UUID) { spot = (version, at) }
    func clear() { spot = nil }

    /// The camera that shows model point `m` (in a part drawn about `centre` through `settle`) at the view's middle, from
    /// outside the part (from its centre's side of the spot), a little closer than the whole part's view.
    static func camera(_ c: OrbitCamera, showing m: SIMD3<Float>, centre: SIMD3<Float>, settle: simd_quatf,
                       radius: Float) -> OrbitCamera {
        let w = centre + settle.act(m - centre)
        var out = c
        let from = w - centre
        if simd_length(from) > 1e-4 {
            let ae = OrbitCamera.azimuthElevation(forDirection: simd_normalize(from), currentAzimuth: c.azimuth)
            out.setOrientation(azimuth: ae.azimuth, elevation: ae.elevation)
        }
        out.target = w
        out.distance = Swift.min(Swift.max(radius * 1.4, out.minDistance), Swift.max(out.distance, out.minDistance))
        return out
    }
}

/// The marked spot on the part: a ring that breathes, drawn where the spot is on screen (it rides the part as the view turns).
struct LatticeFileSpotMarker: View {
    @ObservedObject var spots = LatticeFileSpot.shared
    let frame: LatticeBandChipFrame?
    let version: UUID

    var body: some View {
        if let s = spots.spot, s.version == version, let f = frame, let p = f.project(s.at) {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let breathe = 0.5 + 0.5 * sin(t * 2 * .pi / 1.6)
                ZStack {
                    Circle().stroke(DS.Color.warning.color, lineWidth: 3).frame(width: 30 + 14 * breathe, height: 30 + 14 * breathe)
                        .opacity(0.55 + 0.45 * (1 - breathe))
                    Circle().fill(DS.Color.warning.color).frame(width: 10, height: 10)
                }
                .frame(width: 44, height: 44)
                .background(CornerPairStyle.publish("latticeFileSpot"))   // the hosted tests' frame: the spot, marked
                .position(p)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
