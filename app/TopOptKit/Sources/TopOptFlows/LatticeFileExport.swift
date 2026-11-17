// LatticeFileExport — the EXPORT button (his go 2026-11-13): the print file, made on the Mac from the SAME layout the new engine's
// preview draws (contract: docs/design/lattice-rebuild/04-layout-file-job.md). The app sends the model (with its painted-faces
// sidecar, as every job does) and a `lattice_file` job whose `layout` is the preview's own settings under the bridge's names; the
// worker runs `topopt-cli lattice-file`; the app fetches `lattice.stl` and `lattice_file.json` and offers the file to save or share.
// Shown only with "New engine (test)" on, on Lattice Setup, above the preview's lines.
import Foundation
import SwiftUI
import TopOptKit
import TopOptDesign

// MARK: the job

public enum LatticeFileJob {
    public static let outputName = "lattice.stl"
    public static let reportName = "lattice_file.json"

    /// Every field of the preview's settings, by its Swift name → its key in the job's `layout` (the bridge's names). The test
    /// holds this table to `Settings` itself, so a setting added later can never be left out of the file silently.
    public static let fieldKeys: [String: String] = [
        "allLattice": "all_lattice", "beadMM": "bead_mm", "minStrutLines": "min_strut_lines", "minWallMM": "min_wall_mm",
        "rimMM": "rim_mm", "coverMM": "cover_mm", "regions": "region_*", "protect": "protect_*", "topology": "topology",
        "algorithm": "algorithm", "cellMM": "cell_mm", "cellMaxMM": "cell_max_mm", "cellMinMM": "cell_min_mm",
        "minCellsAcross": "min_cells_across", "gradeToShape": "grade_to_shape", "bandMM": "band_mm", "bandCellMM": "band_cell_mm",
        "perRegion": "per_region", "dial": "dial", "regionDials": "dial_region/dial_value", "strutWidthMM": "strut_width_mm",
        "allowQuilt": "allow_quilt", "strength": "strength", "bars": "bars", "joinLoose": "join_loose", "skin": "skin",
        "skinWidthMM": "skin_width_mm", "skinReachCells": "skin_reach_cells", "dropLoose": "drop_loose",
        "smallCellsInThinWalls": "small_cells_in_thin_walls", "oneGrid": "one_grid",
        "byStress": "by_stress", "dialLight": "dial_light", "dialHeavy": "dial_heavy", "widthLightMM": "width_light_mm",
        "widthHeavyMM": "width_heavy_mm", "cellsByStress": "cells_by_stress", "referenceMPa": "reference_mpa",
        "percentile": "percentile", "response": "response", "maxStep": "max_step",
    ]

    /// The stress result's name beside the job (core's top-level "demand"; the demand file format of 04-layout-file-job.md).
    public static let demandName = "demand.bin"

    /// ★ Install 3, the strength check (LatticeReview's shape, 11-17): beside the job, the run job a Lattice run writes today
    /// (`lattice_part`: loads, supports, material, safety margin, build direction, voxel size), named by the job's
    /// `strength_job`. Absent = no check and no block (rule V2); Aesthetic never sends it (U9); Organic never reaches here.
    public static let strengthJobName = "strength_job.json"
    /// ★ Whether the core the app and the Mac run reads `strength_job` (LatticeReview's install3-strength): OFF until that core
    /// is merged into the release — a core that does not know the key refuses the whole job.
    public static let strengthWired = false
    /// Whether a part's print file carries the strength check: Structural only (U9), on a core that reads it.
    public static func checksStrength(_ l: LatticeSettings, wired: Bool = strengthWired) -> Bool {
        wired && (l.stageMode ?? .structural) == .structural && l.resolvedAlgorithm != "organic"   // (LatticeLayoutPreview.draws)
    }

    /// The stress result as core reads it (04-layout-file-job.md, the demand file): "TODEMAND", int32 version 1, int32 nx ny
    /// nz, float64 origin xyz (the grid's LOW CORNER), float64 spacing, then nx*ny*nz float32 von Mises MPa, x fastest;
    /// little-endian.
    public static func demandFile(_ f: LatticeDemandField) -> Data {
        var d = Data("TODEMAND".utf8)
        func i32(_ v: Int) { var x = Int32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f64(_ v: Double) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        i32(1); i32(f.nx); i32(f.ny); i32(f.nz)
        f64(f.origin.x); f64(f.origin.y); f64(f.origin.z); f64(f.spacingMM)
        d.reserveCapacity(d.count + 4 * f.vonMises.count)
        for v in f.vonMises { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        return d
    }

    /// Whether the job needs the stress result: By stress or cell size by stress, for the part or for any area.
    public static func needsStress(_ s: LatticeLayoutSession.Settings) -> Bool {
        s.byStress || s.cellsByStress || s.regions.contains { $0.own.byStress == true || $0.own.cellsByStress == true }
    }

    /// The job document, keys sorted (the same settings give the same bytes).
    public static func build(_ s: LatticeLayoutSession.Settings, modelName: String, linearDeflection: Double = 0,
                             demand: String? = nil, strengthJob: String? = nil) throws -> Data {
        var layout: [String: Any] = [
            "all_lattice": s.allLattice, "bead_mm": s.beadMM, "min_strut_lines": s.minStrutLines, "min_wall_mm": s.minWallMM,
            "rim_mm": s.rimMM, "cover_mm": s.coverMM,
            "region_ids": s.regions.map { Int($0.id) }, "region_no_lattice": s.regions.map { $0.noLattice ? 1 : 0 },
            "region_depth_mm": s.regions.map(\.depthMM), "region_expand_mm": s.regions.map(\.expandMM),
            "region_face_counts": s.regions.map { $0.faces.count }, "region_faces": s.regions.flatMap { $0.faces.map { Int($0) } },
            "protect_ids": s.protect.map { Int($0.id) }, "protect_depth_mm": s.protect.map(\.depthMM),
            "protect_face_counts": s.protect.map { $0.faces.count }, "protect_faces": s.protect.flatMap { $0.faces.map { Int($0) } },
            "topology": s.topology, "algorithm": s.algorithm, "cell_mm": s.cellMM, "cell_max_mm": s.cellMaxMM,
            "cell_min_mm": s.cellMinMM, "min_cells_across": Int(s.minCellsAcross), "grade_to_shape": s.gradeToShape,
            "band_mm": s.bandMM, "band_cell_mm": s.bandCellMM, "per_region": s.perRegion, "dial": s.dial,
            "dial_region": s.regionDials.map { Int($0.region) }, "dial_value": s.regionDials.map(\.dial),
            "strut_width_mm": s.strutWidthMM, "allow_quilt": s.allowQuilt, "strength": s.strength,
            "small_cells_in_thin_walls": s.smallCellsInThinWalls, "one_grid": s.oneGrid,
            "bars": true,   // a file needs its struts (the job refuses false)
            "join_loose": s.joinLoose, "skin": s.skin, "skin_width_mm": s.skinWidthMM, "skin_reach_cells": s.skinReachCells,
            "drop_loose": s.dropLoose,
        ]
        // ★ his ask 11-14 (D22): the cut pieces, as the preview lays them; the lists only when some piece exists, so a job with
        // none is the bytes it was
        func pieces(_ ps: [LatticeLayoutSession.Piece]) -> Any {
            ps.isEmpty ? NSNull() : ps.map { pc -> [String: Any] in
                ["faces": pc.faces.map { Int($0) },
                 "cuts": pc.cuts.map { c -> [String: Any] in
                     ["point": [c.point.x, c.point.y, c.point.z], "normal": [c.normal.x, c.normal.y, c.normal.z], "strict": c.strict]
                 }]
            }
        }
        if s.regions.contains(where: { !$0.pieces.isEmpty }) { layout["region_pieces"] = s.regions.map { pieces($0.pieces) } }
        if s.protect.contains(where: { !$0.pieces.isEmpty }) { layout["protect_pieces"] = s.protect.map { pieces($0.pieces) } }
        // Install 2: the stress keys, cell size by stress and the size step (core's defaults are the job's bytes as before
        // only by value: the keys are always written, as every other layout key is)
        layout["by_stress"] = s.byStress
        layout["dial_light"] = s.dialLight
        layout["dial_heavy"] = s.dialHeavy
        layout["width_light_mm"] = s.widthLightMM
        layout["width_heavy_mm"] = s.widthHeavyMM
        layout["cells_by_stress"] = s.cellsByStress
        layout["reference_mpa"] = s.referenceMPa
        layout["percentile"] = s.percentile
        layout["response"] = s.response
        layout["max_step"] = s.maxStep
        if s.byStress { layout["per_region"] = false }   // core refuses By stress with Per region
        // an area's own settings (C23), its Finish (S13), zones (D21): one entry per region, null where it states nothing
        func own(_ o: LatticeLayoutSession.AreaOwn) -> Any {
            guard o.any else { return NSNull() }
            var d: [String: Any] = [:]
            if let v = o.algorithm { d["algorithm"] = v }
            if let v = o.cellMM { d["cell_mm"] = v }
            if let v = o.cellMaxMM { d["cell_max_mm"] = v }
            if let v = o.cellMinMM { d["cell_min_mm"] = v }
            if let v = o.minCellsAcross { d["min_cells_across"] = Int(v) }
            if let v = o.gradeToShape { d["grade_to_shape"] = v }
            if let v = o.bandMM { d["band_mm"] = v }
            if let v = o.bandCellMM { d["band_cell_mm"] = v }
            if let v = o.cellsByStress { d["cells_by_stress"] = v }
            if let v = o.byStress { d["by_stress"] = v }
            if let v = o.dial { d["dial"] = v }
            if let v = o.dialLight { d["dial_light"] = v }
            if let v = o.dialHeavy { d["dial_heavy"] = v }
            if let v = o.widthMM { d["strut_width_mm"] = v }
            if let v = o.widthLightMM { d["width_light_mm"] = v }
            if let v = o.widthHeavyMM { d["width_heavy_mm"] = v }
            if let v = o.strength { d["strength"] = v }
            if let v = o.response { d["response"] = v }
            if let v = o.referenceMPa { d["reference_mpa"] = v }
            if let v = o.maxStep { d["max_step"] = v }
            return d
        }
        func finish(_ f: LatticeLayoutSession.RegionFinish) -> Any {
            guard f.any else { return NSNull() }
            var d: [String: Any] = [:]
            if let v = f.rimMM { d["rim_mm"] = v }
            if let v = f.coverMM { d["cover_mm"] = v }
            if let v = f.skin { d["skin"] = v }
            if let v = f.skinWidthMM { d["skin_width_mm"] = v }
            if let v = f.skinReachCells { d["skin_reach_cells"] = v }
            return d
        }
        func zone(_ z: LatticeLayoutSession.Zone?) -> Any {
            guard let z else { return NSNull() }
            let v3 = { (v: SIMD3<Double>) -> [Double] in [v.x, v.y, v.z] }
            switch z.kind {
            case .box: return ["kind": "box", "centre": v3(z.centre), "axes": z.axes.map(v3), "half_mm": v3(z.half)]
            case .cylinder: return ["kind": "cylinder", "centre": v3(z.centre), "axis": v3(z.axes.count > 2 ? z.axes[2] : .zero),
                                    "radius_mm": z.half.x, "half_length_mm": z.half.z]
            }
        }
        if s.regions.contains(where: { $0.own.any }) { layout["region_own"] = s.regions.map { own($0.own) } }
        if s.regions.contains(where: { $0.finish.any }) { layout["region_finish"] = s.regions.map { finish($0.finish) } }
        if s.regions.contains(where: { $0.zone != nil }) { layout["region_zones"] = s.regions.map { zone($0.zone) } }
        var job: [String: Any] = ["mode": "lattice_file", "model": modelName, "output": outputName,
                                  "linear_deflection": linearDeflection, "threads": 0, "layout": layout]
        if let demand { job["demand"] = demand }
        if let strengthJob { job["strength_job"] = strengthJob }   // ★ Install 3
        return try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
    }
}

/// What `lattice_file.json` says, in the few numbers the app shows.
public struct LatticeFileReport: Equatable, Sendable {
    public var ok: Bool
    public var why: String
    public var bars: Int
    public var plasticMM3: Double
    public var partMM3: Double
    public var clean: Bool
    public var posts: Int
    /// ★ Install 3: the strength check's result, when it ran (Structural).
    public var strength: LatticeFileStrength? = nil

    public static func parse(_ d: Data) -> LatticeFileReport? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let l = o["layout"] as? [String: Any] ?? [:], m = o["mesh"] as? [String: Any] ?? [:]
        let p = o["print_check"] as? [String: Any] ?? [:]
        return LatticeFileReport(ok: o["ok"] as? Bool ?? false, why: o["why"] as? String ?? "", bars: l["bars"] as? Int ?? 0,
                                 plasticMM3: m["mm3"] as? Double ?? 0, partMM3: m["part_mm3"] as? Double ?? 0,
                                 clean: p["clean"] as? Bool ?? false, posts: (p["posts"] as? [Any])?.count ?? 0,
                                 strength: (o["strength"] as? [String: Any]).map(LatticeFileStrength.init(block:)))
    }

    /// One plain line: what was made.
    public var line: String {
        let share = partMM3 > 0 ? String(format: " · %.0f%% of the solid part", 100 * plasticMM3 / partMM3) : ""
        return "Print file ready · \(bars) bars\(share)\(clean ? " · layer check clean" : "")"
    }
}

/// ★ Install 3: `lattice_file.json`'s `strength` block (LatticeReview's shape, 11-17: the old check fed from the new layout, the
/// old receipt's names without their prefix), the few numbers the app shows, and its one line.
public struct LatticeFileStrength: Equatable, Sendable {
    public var accepted: Bool
    public var marginWorstCase: Double
    public var safetyMargin: Double
    public var notCertified: Bool
    public var notCertifiedReason: String
    public var massGrams: Double
    public var maxEffectiveVonMisesMPa: Double
    public var marginInPlane: Double
    public var marginInterlayer: Double
    /// The check's own solve, beside the report (the stress and deflection views), or nil.
    public var fields: String?

    public init(block b: [String: Any]) {
        func num(_ k: String) -> Double { (b[k] as? Double) ?? (b[k] as? Int).map(Double.init) ?? 0 }
        accepted = b["accepted"] as? Bool ?? false
        marginWorstCase = num("margin_worst_case")
        safetyMargin = num("safety_margin")
        notCertified = b["not_certified"] as? Bool ?? false
        notCertifiedReason = b["not_certified_reason"] as? String ?? ""
        massGrams = num("mass_grams")
        maxEffectiveVonMisesMPa = num("max_effective_von_mises_mpa")
        marginInPlane = num("margin_in_plane")
        marginInterlayer = num("margin_interlayer")
        fields = b["fields"] as? String
    }

    /// One plain line: whether the latticed part is strong enough for his loads at his safety margin.
    public var line: String {
        if notCertified { return "Strength not checked: " + (notCertifiedReason.isEmpty ? "the check could not judge it" : notCertifiedReason) }
        let mass = massGrams > 0 ? String(format: " · %.0f g", massGrams) : ""
        let margin = String(format: "%.1f×", marginWorstCase)
        return accepted ? "Strong enough · margin \(margin)\(mass)"
                        : "Not strong enough · margin \(margin), needs \(String(format: "%.1f×", safetyMargin))"
    }
}

// MARK: the run on the Mac

public enum LatticeFileRun {
    public static let pollSeconds: TimeInterval = 2
    public static let ceilingSeconds: TimeInterval = 3600

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ d: String) { description = d }
    }

    /// Submit, poll, fetch: blocking, so call it off the main thread. The worker's core must be the app's (a different core lays
    /// a different lattice than the preview drew).
    public static func drive(config: RemoteRunnerConfig, modelPath: String, jobJSON: Data, projectName: String,
                             demand: Data? = nil, strengthJob: Data? = nil,
                             isCancelled: @escaping @Sendable () -> Bool = { false },
                             onState: @escaping @Sendable (_ state: String, _ position: Int?) -> Void = { _, _ in })
        throws -> (stl: Data, report: LatticeFileReport) {
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = config.controlTimeout
            return c
        }())
        func send(_ req: URLRequest) throws -> (Data, Int) {
            var out: (Data, URLResponse)?
            var err: Error?
            let sem = DispatchSemaphore(value: 0)
            session.dataTask(with: req) { d, r, e in
                if let d, let r { out = (d, r) } else { err = e }
                sem.signal()
            }.resume()
            sem.wait()
            guard let out else { throw Failure("The Mac did not answer (\(err?.localizedDescription ?? "no response"))") }
            return (out.0, (out.1 as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let base = config.baseURL
        let (hd, hc) = try send(URLRequest(url: base.appendingPathComponent("health")))
        guard hc == 200, let h = (try? JSONSerialization.jsonObject(with: hd)) as? [String: Any] else {
            throw Failure("The Mac's worker did not answer")
        }
        let fp = (h["fingerprint"] as? String) ?? "unknown"
        guard fp == config.expectedFingerprint else { throw Failure("The Mac runs a different engine: update it first") }

        let model = try Data(contentsOf: URL(fileURLWithPath: modelPath))
        let boundary = "topopt-\(UUID().uuidString)"
        var body = Data()
        var parts = RemoteRun.uploadParts(modelPath: modelPath, model: model, jobJSON: jobJSON, projectName: projectName)
        // ★ Install 2: the stress result beside the job (the worker saves the "demand" part as demand.bin)
        if let demand {
            parts.append(RemoteRun.UploadPart(name: "demand", filename: LatticeFileJob.demandName,
                                              contentType: "application/octet-stream", data: demand))
        }
        // ★ Install 3: the run job the strength check reads (the worker saves the "strength_job" part as strength_job.json)
        if let strengthJob {
            parts.append(RemoteRun.UploadPart(name: "strength_job", filename: LatticeFileJob.strengthJobName,
                                              contentType: "application/json", data: strengthJob))
        }
        for p in parts {
            var head = "Content-Disposition: form-data; name=\"\(p.name)\""
            if let f = p.filename { head += "; filename=\"\(f)\"" }
            if let t = p.contentType { head += "\r\nContent-Type: \(t)" }
            body.append(Data("--\(boundary)\r\n\(head)\r\n\r\n".utf8))
            body.append(p.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var post = URLRequest(url: base.appendingPathComponent("jobs"))
        post.httpMethod = "POST"
        post.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        post.httpBody = body
        let (pd, pc) = try send(post)
        guard pc == 202, let posted = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any],
              let jobID = posted["job_id"] as? String else {
            throw Failure("The Mac refused the job: \(String(data: pd, encoding: .utf8)?.prefix(120) ?? "")")
        }

        let jobURL = base.appendingPathComponent("jobs").appendingPathComponent(jobID)
        let deadline = Date().addingTimeInterval(ceilingSeconds)
        var state = "queued"
        while Date() < deadline {
            if isCancelled() {
                var del = URLRequest(url: jobURL)
                del.httpMethod = "DELETE"
                _ = try? send(del)
                throw Failure("Cancelled")
            }
            let (d, code) = try send(URLRequest(url: jobURL))
            guard code == 200, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                throw Failure("Lost the job on the Mac")
            }
            state = (o["state"] as? String) ?? "unknown"
            onState(state, o["position"] as? Int)   // queued (and how many ahead) or running
            if state == "done" { break }
            if state == "failed" || state == "error" || state == "cancelled" {
                // the CLI's last line carries the same plain why as lattice_file.json (the contract)
                let why = ((o["message"] as? String) ?? "").split(separator: "\n").last.map(String.init) ?? ""
                throw Failure(why.isEmpty ? "The file could not be made" : why)
            }
            Thread.sleep(forTimeInterval: pollSeconds)
        }
        guard state == "done" else { throw Failure("The file was not made within \(Int(ceilingSeconds / 60)) minutes") }
        func file(_ name: String) -> Data? {
            guard let (d, c) = try? send(URLRequest(url: jobURL.appendingPathComponent("files").appendingPathComponent(name))),
                  c == 200, !d.isEmpty else { return nil }
            return d
        }
        guard let rd = file(LatticeFileJob.reportName), let report = LatticeFileReport.parse(rd) else {
            throw Failure("The Mac made the file but its report could not be read")
        }
        guard report.ok else { throw Failure(report.why.isEmpty ? "The file could not be made" : report.why) }
        guard let stl = file(LatticeFileJob.outputName) else { throw Failure("The Mac made the file but it could not be fetched") }
        return (stl, report)
    }
}

// MARK: the button's state

@MainActor
public final class LatticeFileExport: ObservableObject {
    public enum State: Equatable {
        case idle
        case making(since: Date)
        case ready(URL, LatticeFileReport)
        case failed(String)
    }
    @Published public private(set) var state: State = .idle
    /// While making: the Mac's word for the job ("queued" with how many are ahead, or "running").
    @Published public private(set) var onMac: (state: String, ahead: Int?)?
    public static let noMacLine = "Choose a Mac to make the print file"
    public static let checkLine = "Check it in your slicer before printing"
    /// ★ Install 2: By stress with no stress result — one line, and the bar offers the check itself.
    public static let noStressLine = "Grading by stress needs the stress check first"
    @Published public private(set) var needsStressCheck = false

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private var flag = Flag()
    private var token = 0

    public init() {}

    /// Make the print file for this part, with the preview's own settings, on the chosen Mac.
    public func make(project p: ProjectModel, config: RemoteRunnerConfig?, stress: LatticeLayoutPreview.Stress = .init(),
                     strengthJob: Data? = nil) {
        needsStressCheck = false
        guard let config else { state = .failed(Self.noMacLine); return }
        guard let path = p.importedFile?.path else { state = .failed(LatticeLayoutPreview.noPartLine); return }
        let settings = LatticeLayoutPreview.settings(p, referenceMPa: stress.referenceMPa)
        let needs = LatticeFileJob.needsStress(settings)
        var demand: Data?
        if needs {
            guard let f = stress.field else { needsStressCheck = true; state = .failed(Self.noStressLine); return }
            demand = LatticeFileJob.demandFile(f)
        }
        let job: Data
        do {
            job = try LatticeFileJob.build(settings, modelName: (path as NSString).lastPathComponent,
                                           demand: needs ? LatticeFileJob.demandName : nil,
                                           strengthJob: strengthJob == nil ? nil : LatticeFileJob.strengthJobName)
        } catch {
            state = .failed("The job could not be written"); return
        }
        let name = p.name, f = Flag()
        flag = f
        token &+= 1
        let t = token
        state = .making(since: Date())
        Task.detached {
            let outcome: Result<(stl: Data, report: LatticeFileReport), Error> = Result {
                try LatticeFileRun.drive(config: config, modelPath: path, jobJSON: job, projectName: name, demand: demand,
                                         strengthJob: strengthJob,
                                         isCancelled: { f.get() },
                                         onState: { st, pos in
                                             Task { @MainActor [weak self] in
                                                 guard let self, self.token == t else { return }
                                                 self.onMac = (st, pos.map { Swift.max(0, $0 - 1) })
                                             }
                                         })
            }
            var saved: Result<URL, Error>?
            if case let .success(r) = outcome {
                let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Part" : safe) lattice.stl")
                saved = Result { try r.stl.write(to: url, options: .atomic); return url }
            }
            await MainActor.run { [weak self] in
                guard let self, self.token == t else { return }
                switch (outcome, saved) {
                case let (.success(r), .success(url)?): self.state = .ready(url, r.report)
                case let (.failure(e), _): self.state = .failed(FlexibleRowCopy.fit("\(e)", 70))
                default: self.state = .failed("The file could not be saved on this iPad")
                }
            }
        }
    }

    public func cancel() {
        flag.set()
        token &+= 1
        state = .idle
    }

    /// The settings moved: a file made from the old ones no longer matches the preview.
    public func settingsChanged() {
        if case .making = state { return }
        state = .idle
        needsStressCheck = false
    }
}

// MARK: the button

/// The Export bar above the new engine's lines: Export, then making (with the time and Cancel), then the file (Share) or why not.
struct LatticeFileExportBar: View {
    @ObservedObject var export: LatticeFileExport
    let make: () -> Void
    /// ★ Install 2: the one tap that starts the stage's stress check (By stress with no result yet)
    var runStressCheck: (() -> Void)? = nil
    @State private var sharing = false

    private func chip(_ title: String, key: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary ? Color.white : DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.m).frame(height: 32)
                .background(Capsule().fill(primary ? DS.Color.accent.color : DS.Surface.bar.color))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .background(CornerPairStyle.publish(key))
        .accessibilityIdentifier(key)
    }

    private func said(_ text: String, warning: Bool = false, key: String) -> some View {
        Text(text).font(.system(size: 12, weight: warning ? .semibold : .regular))
            .foregroundStyle(warning ? DS.Color.warning.color : DS.Color.textSecondary.color)
            .lineLimit(1).minimumScaleFactor(0.8)
            .background(CornerPairStyle.publish(key))
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            switch export.state {
            case .idle:
                chip("Export print file", key: "new-engine-export", primary: true, make)
            case let .making(since):
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(since))
                    if let m = export.onMac, m.state == "queued" {
                        said("Waiting for the Mac" + (m.ahead.map { $0 > 0 ? " · \($0) ahead" : "" } ?? "")
                             + String(format: " · %d:%02d", s / 60, s % 60), key: "new-engine-export-making")
                    } else {
                        said(String(format: "Making the print file on the Mac · %d:%02d", s / 60, s % 60), key: "new-engine-export-making")
                    }
                }
                chip("Cancel", key: "new-engine-export-cancel") { export.cancel() }
            case let .ready(_, r):
                VStack(alignment: .leading, spacing: 0) {
                    said(r.line, key: "new-engine-export-ready")
                    if let st = r.strength {   // ★ Install 3: the strength check, Structural
                        said(st.line, warning: !st.accepted || st.notCertified, key: "new-engine-export-strength")
                    }
                    said(LatticeFileExport.checkLine, key: "new-engine-export-check")
                }
                chip("Share", key: "new-engine-export-share", primary: true) { sharing = true }
                chip("Again", key: "new-engine-export", make)
            case let .failed(line):
                said(line, warning: true, key: "new-engine-export-failed")
                if export.needsStressCheck, let runStressCheck {
                    chip("Run the stress check", key: "new-engine-export-stress", primary: true, runStressCheck)
                } else {
                    chip("Try again", key: "new-engine-export", make)
                }
            }
        }
        .padding(.horizontal, DS.Space.s)
        .background(Capsule().fill(DS.Surface.bar.color.opacity(0.9)))
        .sheet(isPresented: $sharing) {
            if case let .ready(url, _) = export.state { ShareSheet(items: [url]) }
        }
    }
}
