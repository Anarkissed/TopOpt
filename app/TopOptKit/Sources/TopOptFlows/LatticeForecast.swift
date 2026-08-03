// LatticeForecast.swift — WHAT WOULD HAPPEN, BEFORE THE RUN (task
// 2026-08-03-variant-postprocessing-fix, defects 2/3/4, bars F3–F5, V2).
//
// THE DEFECT THIS FILE EXISTS FOR. The maintainer configured a lattice, spent an
// hour of Mac time on a 128³ ladder, and learned afterwards — from a receipt —
// that variant 038 latticed NOTHING, that 052 latticed 82 voxels of 10,485, that
// all 8 of his include regions covered 99,558 voxels with no material in them,
// and that his boundary choice had emitted zero elements. Every one of those
// numbers is computable from the design and the settings, with no FEA, in well
// under a second. They were simply never computed until it was too late to act.
//
// So core computes them up front (`lattice.forecast_only`, run_job.cpp) and this
// is the app's reading of that document: the counts, the per-reason breakdown,
// the include-on-void count, whether the boundary can emit at all, and the
// EVALUATED remedies — every one of which core produced by re-running the grading
// law with that single parameter changed, never by guessing (PR 276's rule).
//
// Pure value types + pure copy, so the whole surface is headlessly testable.

import Foundation

/// One remedy core actually evaluated: the grading law re-run with a single
/// parameter changed, and the mask it really produced.
public struct LatticeForecastRemedy: Equatable, Sendable {
    /// Human-facing: "halve the cell size", "drop the include regions…".
    public let change: String
    /// The job key it moves ("grading.cell_mm", "lattice.regions").
    public let parameter: String
    /// The value that key would take (nil where the remedy is not a number).
    public let value: Double?
    public let wouldLatticeVoxels: Int
    public let regionVoxels: Int

    public init(change: String, parameter: String, value: Double?,
                wouldLatticeVoxels: Int, regionVoxels: Int) {
        self.change = change
        self.parameter = parameter
        self.value = value
        self.wouldLatticeVoxels = wouldLatticeVoxels
        self.regionVoxels = regionVoxels
    }

    public var latticedFraction: Double {
        regionVoxels > 0 ? Double(wouldLatticeVoxels) / Double(regionVoxels) : 0
    }
}

/// The forecast, as the app reads it.
public struct LatticeForecast: Equatable, Sendable {
    public let variantVolumeFraction: Double
    public let cellSizeMM: Double
    public let cellMode: String
    public let printabilityFloorMM: Double
    public let cellsPerMemberFloor: Double

    public let regionVoxels: Int
    public let wouldLatticeVoxels: Int
    public let wouldStaySolidVoxels: Int

    /// The two predicates, separately — they have OPPOSITE remedies, so summing
    /// them is what made the old receipt unactionable.
    public let memberTooThinVoxels: Int
    public let strutUnprintableVoxels: Int
    /// The subset no cell size can rescue. When this is the whole of the
    /// fallback, offering a cell change would be a wrong answer.
    public let irrecoverableVoxels: Int
    public let widestRejectedMemberMM: Double
    public let memberWidthNeededMM: Double

    public let includeRegions: Int
    public let excludeRegions: Int
    /// Include-region voxels where this variant has no material at all (V2).
    public let includeRegionVoidVoxels: Int

    public let boundary: String
    public let boundaryCanEmit: Bool
    public let boundaryNote: String?

    public let remedies: [LatticeForecastRemedy]

    public init(variantVolumeFraction: Double, cellSizeMM: Double,
                cellMode: String, printabilityFloorMM: Double,
                cellsPerMemberFloor: Double, regionVoxels: Int,
                wouldLatticeVoxels: Int, wouldStaySolidVoxels: Int,
                memberTooThinVoxels: Int, strutUnprintableVoxels: Int,
                irrecoverableVoxels: Int, widestRejectedMemberMM: Double,
                memberWidthNeededMM: Double, includeRegions: Int,
                excludeRegions: Int, includeRegionVoidVoxels: Int,
                boundary: String, boundaryCanEmit: Bool, boundaryNote: String?,
                remedies: [LatticeForecastRemedy]) {
        self.variantVolumeFraction = variantVolumeFraction
        self.cellSizeMM = cellSizeMM
        self.cellMode = cellMode
        self.printabilityFloorMM = printabilityFloorMM
        self.cellsPerMemberFloor = cellsPerMemberFloor
        self.regionVoxels = regionVoxels
        self.wouldLatticeVoxels = wouldLatticeVoxels
        self.wouldStaySolidVoxels = wouldStaySolidVoxels
        self.memberTooThinVoxels = memberTooThinVoxels
        self.strutUnprintableVoxels = strutUnprintableVoxels
        self.irrecoverableVoxels = irrecoverableVoxels
        self.widestRejectedMemberMM = widestRejectedMemberMM
        self.memberWidthNeededMM = memberWidthNeededMM
        self.includeRegions = includeRegions
        self.excludeRegions = excludeRegions
        self.includeRegionVoidVoxels = includeRegionVoidVoxels
        self.boundary = boundary
        self.boundaryCanEmit = boundaryCanEmit
        self.boundaryNote = boundaryNote
        self.remedies = remedies
    }

    public var latticedFraction: Double {
        regionVoxels > 0 ? Double(wouldLatticeVoxels) / Double(regionVoxels) : 0
    }

    /// The threshold at which a configuration is REFUSED rather than merely
    /// reported (bar F4 / P3): more than half the region turning solid is not a
    /// lattice, it is a solid part with decoration, and it must be said before
    /// the run, not after.
    public static let refusalFraction = 0.5

    public var isRefused: Bool {
        regionVoxels > 0 && latticedFraction < Self.refusalFraction
    }

    // MARK: - the copy

    /// The headline: what this configuration would do, in one sentence.
    public var headline: String {
        guard regionVoxels > 0 else {
            return "Nothing in this variant is inside the lattice region, so a "
                 + "lattice run would change nothing."
        }
        let pct = Int((latticedFraction * 100).rounded())
        if wouldLatticeVoxels == 0 {
            return "This configuration would lattice NOTHING — all \(fmt(regionVoxels)) "
                 + "voxels in the region would stay solid."
        }
        return "This configuration would lattice \(pct)% of the region "
             + "(\(fmt(wouldLatticeVoxels)) of \(fmt(regionVoxels)) voxels); "
             + "\(fmt(wouldStaySolidVoxels)) would stay solid."
    }

    /// WHY, per reason, in the user's words. Only reasons that actually account
    /// for voxels appear — a list of zeroes is noise.
    public var reasonLines: [String] {
        var out: [String] = []
        if memberTooThinVoxels > 0 {
            out.append("\(fmt(memberTooThinVoxels)) stay solid because the material "
                     + "there is too thin for this cell: a lattice needs "
                     + "\(trim(cellsPerMemberFloor)) cells across a member, which at "
                     + "\(mm(cellSizeMM)) means \(mm(memberWidthNeededMM)) of "
                     + "thickness. The thickest that failed is \(mm(widestRejectedMemberMM)).")
        }
        if strutUnprintableVoxels > 0 {
            out.append("\(fmt(strutUnprintableVoxels)) stay solid because the struts "
                     + "they would need are thinner than your printer's line width "
                     + "at every cell size available. A LARGER cell prints fatter "
                     + "struts.")
        }
        if includeRegionVoidVoxels > 0 {
            out.append("\(fmt(includeRegionVoidVoxels)) voxels inside your "
                     + "\(includeRegions == 1 ? "include region" : "\(includeRegions) include regions") "
                     + "have no material in this variant — the optimizer left them "
                     + "empty, and a lattice cannot add material. Those parts of the "
                     + "region do nothing.")
        }
        if let note = boundaryNote { out.append(note) }
        return out
    }

    /// WHAT TO DO — evaluated remedies only, best first, and an honest statement
    /// when there is nothing to offer (bars F4/F5).
    ///
    /// `combinedPathAvailable` is the topology+lattice path (the concurrent
    /// multiscale-lattice-to work). Until it lands the limitation is STATED and no
    /// path is offered, because offering one that does not exist is the same
    /// failure as guessing a remedy.
    public func adviceLines(combinedPathAvailable: Bool = false) -> [String] {
        var out: [String] = []
        let better = remedies
            .filter { $0.wouldLatticeVoxels > wouldLatticeVoxels }
            .sorted { $0.wouldLatticeVoxels > $1.wouldLatticeVoxels }
        for r in better {
            let pct = Int((r.latticedFraction * 100).rounded())
            var line = "\(r.change.prefix(1).uppercased())\(r.change.dropFirst()) "
                     + "→ \(pct)% latticed (\(fmt(r.wouldLatticeVoxels)) voxels)"
            if let v = r.value { line += ", \(r.parameter) = \(mm(v))" }
            line += ". Measured, not estimated."
            out.append(line)
        }
        if better.isEmpty && wouldStaySolidVoxels > 0 {
            if irrecoverableVoxels >= memberTooThinVoxels && memberTooThinVoxels > 0 {
                // THE HONEST ANSWER (bar F5). No cell size can rescue these — the
                // members are thinner than the finest printable cell allows. The
                // problem is the design, not the lattice settings.
                out.append("No cell size can lattice this design: the material the "
                         + "optimizer left is thinner than \(mm(memberWidthNeededMM)) "
                         + "almost everywhere, and the finest cell your line width "
                         + "allows is \(mm(printabilityFloorMM)). Nothing on this "
                         + "page will change that.")
                out.append(combinedPathAvailable
                    ? "The variant was optimized assuming SOLID material, so it was "
                    + "never asked to leave latticeable members. Run the combined "
                    + "topology + lattice path instead, which optimizes for the "
                    + "lattice from the start."
                    : "The variant was optimized assuming SOLID material, so it was "
                    + "never asked to leave latticeable members. Latticing it "
                    + "afterwards can only work where the optimizer happened to "
                    + "leave thick enough material.")
            } else {
                out.append("None of the changes tried would lattice more of this "
                         + "variant.")
            }
        }
        return out
    }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private func mm(_ v: Double) -> String { String(format: "%.2f mm", v) }
    private func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    // MARK: - reading core's document

    /// nil when the bytes are not a forecast this build understands — never a
    /// half-read answer presented as a prediction.
    public static func parse(_ data: Data) -> LatticeForecast? {
        guard let o = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              let region = o["region_voxels"] as? Int,
              let latticed = o["would_lattice_voxels"] as? Int,
              let solid = o["would_stay_solid_voxels"] as? Int
        else { return nil }
        let by = o["would_stay_solid_by_reason"] as? [String: Any] ?? [:]
        let remedies = (o["counterfactuals"] as? [[String: Any]] ?? []).compactMap {
            r -> LatticeForecastRemedy? in
            guard let change = r["change"] as? String,
                  let parameter = r["parameter"] as? String,
                  let n = r["would_lattice_voxels"] as? Int,
                  let rv = r["region_voxels"] as? Int else { return nil }
            return LatticeForecastRemedy(change: change, parameter: parameter,
                                         value: r["value"] as? Double,
                                         wouldLatticeVoxels: n, regionVoxels: rv)
        }
        return LatticeForecast(
            variantVolumeFraction: o["variant_volume_fraction"] as? Double ?? 0,
            cellSizeMM: o["cell_size_mm"] as? Double ?? 0,
            cellMode: o["cell_mode"] as? String ?? "",
            printabilityFloorMM: o["printability_floor_mm"] as? Double ?? 0,
            cellsPerMemberFloor: o["cells_per_member_floor"] as? Double ?? 0,
            regionVoxels: region, wouldLatticeVoxels: latticed,
            wouldStaySolidVoxels: solid,
            memberTooThinVoxels: by["member_too_thin_for_cell"] as? Int ?? 0,
            strutUnprintableVoxels: by["strut_unprintable_at_every_cell"] as? Int ?? 0,
            irrecoverableVoxels: by["irrecoverable_by_any_cell_size"] as? Int ?? 0,
            widestRejectedMemberMM: by["widest_rejected_member_mm"] as? Double ?? 0,
            memberWidthNeededMM: by["member_width_needed_mm"] as? Double ?? 0,
            includeRegions: o["include_regions"] as? Int ?? 0,
            excludeRegions: o["exclude_regions"] as? Int ?? 0,
            includeRegionVoidVoxels: o["include_region_void_voxels"] as? Int ?? 0,
            boundary: o["boundary"] as? String ?? "",
            boundaryCanEmit: o["boundary_can_emit"] as? Bool ?? true,
            boundaryNote: o["boundary_note"] as? String,
            remedies: remedies)
    }
}

// MARK: - THE CALL SITE (task 2026-08-03-variant-postprocessing-fix, bar F3)

/// Holds the pre-flight forecast for the lattice page, and drives it.
///
/// *** WHY THIS TYPE EXISTS AT ALL. *** The first cut of bar F3 computed the
/// forecast in core, transported it over the worker protocol, parsed it into
/// `LatticeForecast` and rendered it into the action row — and NOTHING CALLED IT.
/// Every layer was present except the one that invokes, so the handoff read
/// "shipped" and the user saw nothing. That is the same shape as PR 284 (retention
/// built, never called) and PR 289 (31 tests against a path the maintainer could
/// not reach), and it is the reason the review blocked this PR. The forecast is
/// the headline deliverable of the whole task; a headline deliverable with no
/// call site is not a deliverable.
///
/// THE STALENESS RULE IS THE SAME ONE AS EVERYWHERE ELSE. A forecast describes ONE
/// configuration. Showing it against a different one would be a prediction about a
/// job nobody is going to run — so the model records the exact job document it
/// describes and `forecast(for:)` returns nil on any mismatch. Identity is the
/// DOCUMENT, not a hand-listed set of "forecast-relevant settings": two
/// configurations that build the same job are the same forecast by construction,
/// and there is no second list to drift out of sync with `RelatticeJobBuilder`.
@MainActor
public final class LatticeForecastModel: ObservableObject {

    public enum State: Equatable, Sendable {
        /// Nothing to forecast — no variant, or the run kept no design to read.
        case idle
        case running
        case ready(LatticeForecast)
        /// The forecast could not be produced. Said out loud rather than silently
        /// leaving the page as if no configuration problem existed.
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    /// The job document `state` describes. nil while idle.
    public private(set) var describes: Data?

    private var inFlight: Task<Void, Never>?

    /// `nonisolated` so a View's default argument can construct one: every stored
    /// property has a default and none of them is touched here.
    public nonisolated init() {}

    /// The forecast IF it describes `job` — never otherwise.
    public func forecast(for job: Data?) -> LatticeForecast? {
        guard let job, describes == job, case let .ready(f) = state else { return nil }
        return f
    }

    /// Whether a forecast for exactly `job` is being computed right now.
    public func isRunning(for job: Data?) -> Bool {
        guard let job, describes == job, case .running = state else { return false }
        return true
    }

    /// Why the forecast for exactly `job` could not be produced.
    public func failure(for job: Data?) -> String? {
        guard let job, describes == job, case let .failed(why) = state else { return nil }
        return why
    }

    /// Ask for a forecast of `job`.
    ///
    /// DEBOUNCED, because the inputs are live controls: dragging a cell-size
    /// slider would otherwise submit a job per frame at a worker that runs one at a
    /// time. The forecast itself is cheap (core measured 0.09–0.55 s against 4–39 s
    /// for the run it forecasts) but the round trip is not free, so the settings
    /// have to stop moving first.
    ///
    /// Re-requesting the SAME document is a no-op — a body re-evaluation must not
    /// re-submit work. A DIFFERENT document cancels whatever is in flight: its
    /// answer is about a configuration the user has already left.
    ///
    /// A FAILED forecast also stays failed for that document, rather than retrying
    /// on every body pass at a worker that may be down. Changing any setting
    /// re-asks, and so does closing and reopening the page (`clear()` drops the
    /// record of what was asked), so there are two ordinary ways back without a
    /// retry loop hammering an unreachable Mac.
    public func request(_ job: Data?,
                        debounceNanoseconds: UInt64 = 600_000_000,
                        drive: @escaping @Sendable (Data) async throws -> LatticeForecast) {
        guard let job else { clear(); return }
        if describes == job, state != .idle { return }
        inFlight?.cancel()
        describes = job
        state = .running
        inFlight = Task { [weak self] in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            if Task.isCancelled { return }
            do {
                let f = try await drive(job)
                guard !Task.isCancelled else { return }
                // The answer is only published if the question has not moved.
                guard let self, self.describes == job else { return }
                self.state = .ready(f)
            } catch {
                guard !Task.isCancelled, let self, self.describes == job else { return }
                self.state = .failed("\(error)")
            }
        }
    }

    /// Drop everything — the page was closed, or there is no variant to forecast.
    public func clear() {
        inFlight?.cancel()
        inFlight = nil
        describes = nil
        state = .idle
    }
}

/// The forecast as the REVIEW DRAWER shows it: a title, the headline, the
/// per-reason lines and the evaluated remedies — pure, so the whole surface is
/// testable without a view.
public struct LatticeForecastPanel: Equatable, Sendable {
    public let title: String
    /// One line when there is nothing to show yet (running / unavailable / no
    /// variant); nil once there is a real forecast.
    public let placeholder: String?
    public let headline: String?
    public let reasons: [String]
    public let advice: [String]
    /// Draw it as a warning rather than plain information.
    public let warn: Bool

    public static func compute(state: LatticeForecastModel.State,
                               describesCurrentJob: Bool,
                               combinedPathAvailable: Bool = false)
        -> LatticeForecastPanel {
        let title = "What this would produce"
        // A forecast that describes a DIFFERENT configuration is treated exactly
        // as no forecast: the user changed something, and the last answer is about
        // the thing they changed away from.
        guard describesCurrentJob else {
            return LatticeForecastPanel(
                title: title,
                placeholder: "Checking what these settings would lattice…",
                headline: nil, reasons: [], advice: [], warn: false)
        }
        switch state {
        case .idle:
            return LatticeForecastPanel(
                title: title,
                placeholder: "Open this page from a finished variant to see what a "
                    + "lattice run would produce before you spend one.",
                headline: nil, reasons: [], advice: [], warn: false)
        case .running:
            return LatticeForecastPanel(
                title: title,
                placeholder: "Checking what these settings would lattice…",
                headline: nil, reasons: [], advice: [], warn: false)
        case let .failed(why):
            return LatticeForecastPanel(
                title: title,
                placeholder: "Couldn’t check these settings up front (\(why)). The "
                    + "run will still tell you — afterwards.",
                headline: nil, reasons: [], advice: [], warn: true)
        case let .ready(f):
            return LatticeForecastPanel(
                title: title, placeholder: nil, headline: f.headline,
                reasons: f.reasonLines,
                advice: f.adviceLines(combinedPathAvailable: combinedPathAvailable),
                warn: f.isRefused)
        }
    }
}
