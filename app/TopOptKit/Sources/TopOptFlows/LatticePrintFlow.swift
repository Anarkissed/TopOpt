// LatticePrintFlow — ★ his iPad notes 2026-11-22 (img 47): "Even though I don't have 'Print-accurate Preview' selected, the blue
// lattice button continues to show the lattice generating the print version. If not selected, do we really need to generate a
// print-accurate preview before exporting? If so, do it *after* pressing the 'Export' button. Generate the print-accurate
// preview first, then change the button to 'Approved' and that should lead to the export page/modal."
//
// Yes: the print file IS the exact lattice. Only his press for the file lays it (the Lattice button, or ⌃ Export…); the button
// then reads "Making the print file" for the exact lay and the file's job together, and once the file is made and passes its
// checks, "Approved" · "Tap to export", whose tap opens the export (Results on the file's result, where Export is — the page ⌃
// Export… opens). Any change to the part or the lattice settings gives the button back. A file that fails its checks keeps
// today's way (Results opens by itself; the certify wizard walks an Organic part through it).
// The state lives here, never as @State on the workspace (WorkspaceBodySizeTests), and only this button observes it.
import Foundation
import SwiftUI
import TopOptKit

/// The button's words for the print file (five at most each).
enum LatticePrintFlowCopy {
    static let making = "Making the print file"
    static let approved = "Approved"
    static let approvedLine = "Tap to export"
}

@MainActor
public final class LatticePrintFlow: ObservableObject {
    public static let shared = LatticePrintFlow()

    public enum Phase: Equatable { case idle, making, approved }
    @Published public private(set) var phase: Phase = .idle
    /// The version it is for, and what the file is made from (a change of either gives the button back).
    private(set) var projectID: UUID?
    private(set) var key: LatticeLayoutPreview.LayInputs?
    /// When he asked for the file, and when its job was sent (after the exact lay).
    private(set) var started: Date?
    private(set) var fileStarted: Date?
    /// How long the last file's job took for a part (s): the ring's count-down next time.
    private var fileSeconds: [String: Double] = [:]

    public init() {}

    /// He asked for the print file (the Lattice button, or ⌃ Export…).
    func begin(project id: UUID, key: LatticeLayoutPreview.LayInputs?, now: Date = Date()) {
        projectID = id; self.key = key; started = now; fileStarted = nil
        phase = .making
    }
    /// The exact lattice is laid: the file's job is sent.
    func fileSent(now: Date = Date()) {
        guard phase == .making else { return }
        fileStarted = now
    }
    /// The file's run landed: approved when it passes its checks (true: the caller leaves Results shut); otherwise back to normal
    /// (today's way: Results opens, the wizard walks it).
    func landed(passes: Bool, now: Date = Date()) -> Bool {
        guard phase == .making else { return false }
        if let f = fileStarted, let path = key?.path { fileSeconds[path] = now.timeIntervalSince(f) }
        phase = passes ? .approved : .idle
        if !passes { key = nil }
        return passes
    }
    /// It stopped short (refused, failed, cancelled): the button goes back.
    func ended() {
        guard phase != .idle else { return }
        phase = .idle; key = nil; started = nil; fileStarted = nil
    }

    func isMaking(_ id: UUID) -> Bool { phase == .making && projectID == id }
    /// Approved for this version with exactly these inputs (`current` is read only while approved).
    func isApproved(_ id: UUID, current: () -> LatticeLayoutPreview.LayInputs?) -> Bool {
        guard phase == .approved, projectID == id, let key else { return false }
        return current() == key
    }

    // MARK: what the Lattice button shows

    public enum Tap: Equatable { case normal, openExport, viewRun, wait }
    struct Look {
        var title: String
        var subtitle: String
        var state: DSRunButton.State
        var progress: DSRunButton.Progress?
        var tap: Tap = .normal
        var marker: String? = nil
    }

    /// The button for this version: the normal one, "Making the print file" (its ring: the exact lay and the file's job
    /// together), or "Approved" · "Tap to export".
    /// ★ his notes 11-23: `saved` — Approved worked out from the version's SAVED print file (AppModel.latticeResultApproved),
    /// read only when this flow is not making one for it, so it survives a relaunch.
    func look(for id: UUID, normal: Look, layProgress: LatticeLayoutPreview.LayProgress?, fileRunning: Bool,
              current: () -> LatticeLayoutPreview.LayInputs?, saved: () -> Bool = { false }) -> Look {
        if isApproved(id, current: current) || (!isMaking(id) && !fileRunning && saved()) {
            return Look(title: LatticePrintFlowCopy.approved, subtitle: LatticePrintFlowCopy.approvedLine, state: .ready,
                        progress: nil, tap: .openExport, marker: "latticeApproved")
        }
        guard isMaking(id), let started, !(fileStarted != nil && !fileRunning) else { return normal }
        let p = DSRunButton.Progress(started: started, expected: expectedS(layProgress), words: LatticePrintFlowCopy.making)
        return Look(title: "Lattice", subtitle: LatticePrintFlowCopy.making,
                    state: .running(LatticePrintFlowCopy.making), progress: p, tap: fileRunning ? .viewRun : .wait,
                    marker: "latticeMakingFile")
    }

    /// How long the whole of it should take from his press (s): the exact lay's own guess and the last file's, when both are
    /// known; nil (a spinner) otherwise.
    func expectedS(_ lay: LatticeLayoutPreview.LayProgress?) -> Double? {
        guard let started, let path = key?.path, let file = fileSeconds[path] else { return nil }
        if let f = fileStarted { return f.timeIntervalSince(started) + file }
        guard let lay, let e = lay.expectedS else { return nil }
        return lay.started.timeIntervalSince(started) + e + file
    }

    /// The file passes its checks: its result is accepted and strong enough, and (Organic) certifies — no wizard to walk.
    static func passes(_ outcome: OptimizeOutcome?, organic: Bool, infillNow: Int) -> Bool {
        guard let v = outcome?.variants.first(where: { $0.accepted }), v.v3Passes else { return false }
        if organic, OrganicCertify.walk(version: UUID(), reportJSON: outcome?.reportJSON, infillNow: infillNow) != nil { return false }
        return true
    }

    /// Tests only: back to nothing.
    func reset() { phase = .idle; projectID = nil; key = nil; started = nil; fileStarted = nil; fileSeconds = [:] }
}

/// The Lattice button, as the print file's flow has it (this view alone follows the flow; the workspace passes today's button).
struct LatticeRunButtonFlow: View {
    @ObservedObject var flow: LatticePrintFlow
    let projectID: UUID
    let normal: LatticePrintFlow.Look
    let layProgress: LatticeLayoutPreview.LayProgress?
    let fileRunning: Bool
    let current: () -> LatticeLayoutPreview.LayInputs?
    /// ★ his notes 11-23: Approved from the version's saved print file (survives a relaunch).
    var saved: () -> Bool = { false }
    let tap: (LatticePrintFlow.Tap) -> Void

    var body: some View {
        let l = flow.look(for: projectID, normal: normal, layProgress: layProgress, fileRunning: fileRunning, current: current,
                          saved: saved)
        DSRunButton(l.title, subtitle: l.subtitle, state: l.state, key: "latticeButton", progress: l.progress) { tap(l.tap) }
            .background(l.marker.map { CornerPairStyle.publish($0) })
    }
}
