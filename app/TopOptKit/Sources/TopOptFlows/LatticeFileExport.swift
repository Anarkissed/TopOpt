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
        "smallCellsInThinWalls": "small_cells_in_thin_walls",
    ]

    /// The job document, keys sorted (the same settings give the same bytes).
    public static func build(_ s: LatticeLayoutSession.Settings, modelName: String, linearDeflection: Double = 0) throws -> Data {
        let layout: [String: Any] = [
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
            "small_cells_in_thin_walls": s.smallCellsInThinWalls,
            "bars": true,   // a file needs its struts (the job refuses false)
            "join_loose": s.joinLoose, "skin": s.skin, "skin_width_mm": s.skinWidthMM, "skin_reach_cells": s.skinReachCells,
            "drop_loose": s.dropLoose,
        ]
        let job: [String: Any] = ["mode": "lattice_file", "model": modelName, "output": outputName,
                                  "linear_deflection": linearDeflection, "threads": 0, "layout": layout]
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

    public static func parse(_ d: Data) -> LatticeFileReport? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let l = o["layout"] as? [String: Any] ?? [:], m = o["mesh"] as? [String: Any] ?? [:]
        let p = o["print_check"] as? [String: Any] ?? [:]
        return LatticeFileReport(ok: o["ok"] as? Bool ?? false, why: o["why"] as? String ?? "", bars: l["bars"] as? Int ?? 0,
                                 plasticMM3: m["mm3"] as? Double ?? 0, partMM3: m["part_mm3"] as? Double ?? 0,
                                 clean: p["clean"] as? Bool ?? false, posts: (p["posts"] as? [Any])?.count ?? 0)
    }

    /// One plain line: what was made.
    public var line: String {
        let share = partMM3 > 0 ? String(format: " · %.0f%% of the solid part", 100 * plasticMM3 / partMM3) : ""
        return "Print file ready · \(bars) bars\(share)\(clean ? " · layer check clean" : "")"
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
        for p in RemoteRun.uploadParts(modelPath: modelPath, model: model, jobJSON: jobJSON, projectName: projectName) {
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
    public func make(project p: ProjectModel, config: RemoteRunnerConfig?) {
        guard let config else { state = .failed(Self.noMacLine); return }
        guard let path = p.importedFile?.path else { state = .failed(LatticeLayoutPreview.noPartLine); return }
        let job: Data
        do {
            job = try LatticeFileJob.build(LatticeLayoutPreview.settings(p), modelName: (path as NSString).lastPathComponent)
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
                try LatticeFileRun.drive(config: config, modelPath: path, jobJSON: job, projectName: name, isCancelled: { f.get() },
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
    }
}

// MARK: the button

/// The Export bar above the new engine's lines: Export, then making (with the time and Cancel), then the file (Share) or why not.
struct LatticeFileExportBar: View {
    @ObservedObject var export: LatticeFileExport
    let make: () -> Void
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
                    said(LatticeFileExport.checkLine, key: "new-engine-export-check")
                }
                chip("Share", key: "new-engine-export-share", primary: true) { sharing = true }
                chip("Again", key: "new-engine-export", make)
            case let .failed(line):
                said(line, warning: true, key: "new-engine-export-failed")
                chip("Try again", key: "new-engine-export", make)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .background(Capsule().fill(DS.Surface.bar.color.opacity(0.9)))
        .sheet(isPresented: $sharing) {
            if case let .ready(url, _) = export.state { ShareSheet(items: [url]) }
        }
    }
}
