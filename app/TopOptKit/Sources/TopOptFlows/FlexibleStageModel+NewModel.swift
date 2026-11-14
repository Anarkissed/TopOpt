// FlexibleStageModel+NewModel — "Upload new version" on a Flexible part, step B (his pick 2 of 2026-11-12): an edge or corner
// press is RE-FOUND on the new model where the faces it joined still meet, else it is lost. Its strip was drawn on the old
// model's shape (FlexibleNewModel.carry matched its faces and listed it in `newModel.refind`); when the new version's scene
// opens, the page's own edge list (the meet, FlexibleEdgeCandidates) is read once and each listed press takes the candidate of
// its kind whose faces are its faces — its strip made again there (FlexibleEdgeStrips.strip(for:), the [Done] path's), every
// setting kept (weight group, curves, depth; an arrow on the halfway moves to the new halfway). No such candidate: the press
// waits in `newModel.lostPresses` ("Pick its edge"). One change, after the open; never an undo step of its own.
import Foundation
import simd

/// The words of "Upload new version" on a Flexible part (§3 plain words, one line each, ≤ 44).
public enum FlexibleNewModelCopy {
    public static let pickFace = "Pick its face"
    public static let pickEdge = "Pick its edge"
    public static let remove = "Remove"
    public static let tapItsFace = "Tap its face on the part"
    public static let aFace = "A face"
    /// The readiness line (blocking: the run waits), as Topology's "A group lost its faces · Pick its faces".
    public static func lostLine(_ n: Int) -> String {
        n == 1 ? "A pressed face lost its face · Pick its face" : "\(n) pressed faces lost their faces · Pick them"
    }
    public static let lostPill = "Fix: pick a lost face"
    /// A lost item's row: its old name, what it was ("Front face · was pressed").
    public static func row(_ name: String, _ what: String) -> String { FlexibleRowCopy.fit("\(name) · \(what)") }
    public static let wasPressed = "was pressed"
    public static let wasResting = "was resting"
    public static let wasEdge = "was an edge press"
    public static let wasCorner = "was a corner press"
    public static let wasTilted = "was a tilted press"
}

/// One thing waiting for a face, in the list's order: the faces, then the presses.
public enum FlexibleLostItem: Equatable, Sendable {
    case face(FlexibleFaceSettings)
    case press(FlexiblePress)
    /// An edge or corner press: picked again on the edges list, never by a face tap.
    public var needsEdge: Bool { if case .press(let p) = self { return p.strip != nil }; return false }
}

extension FlexibleNewModelState {
    public var lostItems: [FlexibleLostItem] { lostFaces.map { .face($0) } + lostPresses.map { .press($0) } }
}

extension FlexibleStageModel {

    /// The things waiting for a face (empty when none).
    public var lostItems: [FlexibleLostItem] { settings.newModel?.lostItems ?? [] }

    /// [Pick its face]: the next face tap gives lost item `n` that face; an edge or corner press opens the edges list instead
    /// (the edge he picks takes its settings: `finishEdgePick`).
    public func pickLost(_ n: Int) {
        guard lostItems.indices.contains(n) else { return }
        lostPick = n
        if lostItems[n].needsEdge {
            startEdgePick()
        } else {
            toast = FlexibleNewModelCopy.tapItsFace
        }
    }

    /// [Remove]: lost item `n` is let go (one undo step).
    public func dropLost(_ n: Int) {
        guard lostItems.indices.contains(n) else { return }
        if lostPick == n { lostPick = nil }
        edit { s in Self.drop(&s, n) }
    }

    /// The face he tapped while picking: lost item `lostPick` takes `region`, every setting with it (one undo step). A face
    /// already pressed, resting or deleted is not taken (the toast says so; the pick stays armed).
    func assignLost(to region: Int) {
        guard let n = lostPick, lostItems.indices.contains(n) else { lostPick = nil; return }
        if settings.face(region) != nil || settings.pressRegions.contains(region) {
            toast = FlexibleRowCopy.fit("\(displayName(region)) is already set · tap another")
            return
        }
        lostPick = nil
        edit { s in Self.assign(&s, n, to: region) }
        select(region)
    }

    /// Lost item `n` onto `region` (pure; FlexibleNewModelTests).
    static func assign(_ s: inout FlexibleStageSettings, _ n: Int, to region: Int) {
        guard var state = s.newModel else { return }
        let items = state.lostItems
        guard items.indices.contains(n) else { return }
        switch items[n] {
        case .face(var f):
            f.faceRegionID = region
            s.faces.append(f)
            state.lostFaces.remove(at: n)
        case .press(var p):
            guard p.strip == nil else { return }   // an edge press is picked on the edges list
            p.regions = [region]
            p.settings.faceRegionID = region
            p.drawnIn = nil
            s.presses = (s.presses ?? []) + [p]
            state.lostPresses.remove(at: n - state.lostFaces.count)
        }
        if let i = s.removedRegions?.firstIndex(of: region) {
            s.removedRegions?.remove(at: i)
            if s.removedRegions?.isEmpty == true { s.removedRegions = nil }   // nil, never [] (old projects encode as before)
        }
        s.newModel = state.isEmpty ? nil : state
    }

    /// Lost item `n` let go (pure).
    static func drop(_ s: inout FlexibleStageSettings, _ n: Int) {
        guard var state = s.newModel else { return }
        if n < state.lostFaces.count { state.lostFaces.remove(at: n) }
        else if n - state.lostFaces.count < state.lostPresses.count { state.lostPresses.remove(at: n - state.lostFaces.count) }
        s.newModel = state.isEmpty ? nil : state
    }

    /// An edges pick made for lost press `lostPick` ([Done]): the first new press takes the lost one's settings (weight, curves,
    /// depth; its strip and arrow are the new pick's) and the lost one is let go. Called by finishEdgePick.
    func adoptLostEdgeSettings(newPress id: UUID) {
        guard let n = lostPick, lostItems.indices.contains(n), case .press(let old) = lostItems[n], old.strip != nil else { return }
        lostPick = nil
        edit { s in
            guard var p = s.press(id) else { return }
            var f = old.settings
            f.faceRegionID = p.settings.faceRegionID
            f.squeezeGroup = p.settings.squeezeGroup
            f.weightFrom = p.settings.weightFrom
            p.settings = f
            s.presses = (s.presses ?? []).map { $0.id == id ? p : $0 }
            Self.drop(&s, n)
        }
    }

    /// Tests only: print what the re-find read (the meet, the candidates, a refused strip).
    nonisolated(unsafe) static var traceRefind = false

    /// Re-find every press `newModel.refind` lists (the open calls it once the scene is ready).
    func refindNewModelPresses() async {
        guard !refindInFlight, let ids = settings.newModel?.refind, !ids.isEmpty else { return }
        refindInFlight = true
        defer { refindInFlight = false }
        let held = (settings.presses ?? []).filter { ids.contains($0.id) }
        // ONE undo step: the presses come off (their own strips cut their faces into pieces, so the edge list would see the
        // pieces' edges), the edge list is read over the WHOLE faces — as a fresh pick on the new model would — and each
        // goes back on its re-found edge, or waits for a face
        project.sealUndoStep()
        defer { project.sealUndoStep() }
        edit({ s in
            let rest = (s.presses ?? []).filter { !ids.contains($0.id) }
            s.presses = rest.isEmpty ? nil : rest
        }, recompute: false)
        // the faces changed (the strips' pieces are gone): core answers once the scene opens on them
        await reopenAndWait()
        var found: [UUID: FlexibleStrip] = [:]
        let facts = try? await meetFacts()
        let meet = await meetOffMain()
        if Self.traceRefind {
            print("FLEX-UPLOAD refind: facts \(facts != nil), meet \(meet != nil), held \(held.map { $0.strip.map { s in s.members.map(\.face) } ?? [] })")
        }
        if let facts, let meet {
            let list = FlexibleEdgeCandidates.make(meet: meet, facts: facts, removed: Set(settings.removedRegions ?? []),
                                                   name: { [weak self] r in self?.displayName(r) ?? FlexibleRowCopy.aFace })
            if Self.traceRefind {
                print("FLEX-UPLOAD refind: unread \(list.unread ?? "-"), candidates \(list.candidates.map { "\($0.kind.rawValue)\($0.members)" })")
            }
            var others = (settings.presses ?? []).compactMap(\.strip)
            for p in held {
                guard let st = p.strip else { continue }
                let want = Set(st.members.map(\.face))
                let kind: FlexibleEdgeCandidates.Kind = st.kind == .corner ? .corner : .edge
                guard let c = list.candidates.first(where: { $0.kind == kind && Set($0.members) == want }) else { continue }
                switch FlexibleEdgeStrips.strip(for: c, label: FlexibleRowCopy.candidateLabel(c), order: st.order,
                                                meet: meet, facts: facts, faceRegions: restoredFaceRegions,
                                                existing: others,
                                                name: { [weak self] r in self?.displayName(r) ?? FlexibleRowCopy.aFace }) {
                case .success(var n):
                    n.order = st.order
                    found[p.id] = n
                    others.append(n)
                case .failure(let why):
                    if Self.traceRefind { print("FLEX-UPLOAD refind: strip refused: \(why.line)") }
                }
            }
        }
        edit { s in Self.applyRefind(&s, held: held, found: found) }
    }

    /// Open the scene on the faces as they are now and wait (at most 2 min) until it is ready on them.
    private func reopenAndWait() async {
        guard openedKey != currentSceneKey || sceneState != .ready else { return }
        openScene()
        let end = Date().addingTimeInterval(120)
        while !(sceneState == .ready && openedKey == currentSceneKey), Date() < end {
            if case .failed = sceneState { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The presses `held` back in (in their order), each on its re-found strip, or waiting for a face (pure:
    /// FlexibleNewModelRefindTests drives it with strips of its own). A press of `held` still in `s` is replaced, not doubled.
    static func applyRefind(_ s: inout FlexibleStageSettings, held: [FlexiblePress], found: [UUID: FlexibleStrip]) {
        var state = s.newModel ?? FlexibleNewModelState()
        let asked = Set(held.map(\.id))
        var kept = (s.presses ?? []).filter { !asked.contains($0.id) }
        for p in held {
            guard let n = found[p.id] else {
                if !state.lostPresses.contains(where: { $0.id == p.id }) { state.lostPresses.append(p) }
                continue
            }
            var q = p
            q.strip = n
            if FlexiblePress.Snap(p.snap) == .halfway, let h = n.halfway { q.direction = h }   // on the halfway: the new one
            kept.append(q)
        }
        s.presses = kept.isEmpty ? nil : kept
        state.refind.removeAll { asked.contains($0) }
        s.newModel = state.isEmpty ? nil : state
    }
}
