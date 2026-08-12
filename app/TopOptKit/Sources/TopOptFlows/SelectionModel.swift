// SelectionModel.swift — the M7.5 face-selection groups state machine.
//
// This is a faithful port of the design's group logic (docs/design/TopOpt.dc.html:
// `groups[]`, `nextColor`, `activeGroupId`, `_makeGroup`, `_pickFace`, `addGroup`,
// the group-row rename). A "face" here is a B-rep face id — the per-triangle
// `faceIDs` the bridge already supplies for a STEP import (ImportedMesh); a group
// is a set of those ids, so tagging a group tags every voxel against its faces
// (ROADMAP M7.5). Groups are auto-named A/B/C…, colour-coded round-robin from
// `DS.Color.groupPalette`, renamable and removable, with an active-group highlight
// and a face-count label per group — exactly the design's Selections panel.
//
// It is a pure value type (no SwiftUI, no GPU, no bridge) so the whole
// create/pick/rename/remove/colour/active/count logic is unit-tested headlessly
// (the M7 /app/ verification standard); the SwiftUI panel renders over it and the
// SelectionTagger maps it onto the bridge.

import Foundation
import TopOptDesign

/// A B-rep face id — the unit of selection. For a STEP import these are the
/// per-triangle `ImportedMesh.faceIDs` the bridge supplies (STL has none).
public typealias FaceID = Int32

/// How a selection group is applied to the voxel grid at optimize time. In the
/// design a group with force arrows is a Load and an arrow-less group is a fixed
/// anchor (Fixture); Frozen (keep-in/keep-out passive regions, M3.7) is the third
/// core tagging role. The mapping onto the bridge lives in `SelectionTagger`.
public enum GroupRole: String, CaseIterable, Sendable {
    /// Clamped mounting face — `tag_step_face(asFixture: true)`.
    case fixture
    /// Loaded face — `tag_step_face(asFixture: false)`.
    case load
    /// Passive keep-in/keep-out region — needs `mask_step_face` (see SelectionTagger).
    case frozen
}

/// One selection group: an auto-named, colour-coded set of B-rep faces (the
/// design's `groups[]` entry). The colour is a slot in `DS.Color.groupPalette`.
public struct SelectionGroup: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    /// User-editable label; auto-seeded "Group A", "Group B", … (design `name`).
    public var name: String
    /// Palette slot assigned round-robin at creation (design `nextColor % COLORS`).
    /// `color` resolves it against `DS.Color.groupPalette`.
    public var colorIndex: Int
    /// The face ids in this group, in selection order, deduplicated (design `faces`).
    public private(set) var faces: [FaceID]
    /// ★ THE REGIONS in this group (task 2026-08-14-face-regions §1). A union of
    /// 23 blend faces is ONE entry here instead of 23 in `faces` — which is the
    /// whole point of the layer. A group carries both: a region and a plain face
    /// are both selections, and the run tags them the same way.
    ///
    /// DECODED WITH `decodeIfPresent` (see `init(from:)`): a project saved before
    /// this field existed must still open, and it opens with no regions, which is
    /// exactly the group it was.
    public private(set) var regionIDs: [RegionID]

    public init(id: UUID = UUID(), name: String, colorIndex: Int, faces: [FaceID] = [],
                regionIDs: [RegionID] = []) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.faces = faces
        self.regionIDs = regionIDs
    }

    private enum CodingKeys: String, CodingKey { case id, name, colorIndex, faces, regionIDs }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorIndex = try c.decode(Int.self, forKey: .colorIndex)
        faces = try c.decode([FaceID].self, forKey: .faces)
        regionIDs = try c.decodeIfPresent([RegionID].self, forKey: .regionIDs) ?? []
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colorIndex, forKey: .colorIndex)
        try c.encode(faces, forKey: .faces)
        // Written only when non-empty, so a project with no regions produces the
        // exact project.json it produced before this field existed.
        if !regionIDs.isEmpty { try c.encode(regionIDs, forKey: .regionIDs) }
    }

    /// Add / remove regions. A region belongs to exactly one group, the same
    /// invariant `faces` keeps.
    mutating func addRegions(_ ids: [RegionID]) {
        for r in ids where !regionIDs.contains(r) { regionIDs.append(r) }
    }

    mutating func removeRegions(_ ids: [RegionID]) {
        let drop = Set(ids)
        regionIDs.removeAll { drop.contains($0) }
    }

    /// The group's colour, from the design palette (`this.COLORS`), by `colorIndex`.
    public var color: RGBA {
        let palette = DS.Color.groupPalette
        return palette[((colorIndex % palette.count) + palette.count) % palette.count]
    }

    /// Number of faces (design `g.faces.length`) — the face-count chip value.
    public var faceCount: Int { faces.count }

    /// ROWS in this group: plain faces plus regions. A union collapses 23 faces
    /// into one row, so this is the number the chip should show — the count of
    /// things the user selected, not the count of things the CAD happened to
    /// have. `faceCount` stays as it was for every existing caller.
    public var selectionCount: Int { faces.count + regionIDs.count }

    /// The design's "N face" / "N faces" chip label.
    public var faceLabel: String { faceCount == 1 ? "1 face" : "\(faceCount) faces" }

    /// The chip label once regions are in play: "1 region · 3 faces", or the
    /// plain face label when the group holds no region (byte-identical copy for
    /// every project that has not used the layer).
    public var selectionLabel: String {
        guard !regionIDs.isEmpty else { return faceLabel }
        let r = regionIDs.count == 1 ? "1 region" : "\(regionIDs.count) regions"
        return faces.isEmpty ? r : "\(r) · \(faceLabel)"
    }

    /// Add face ids, preserving order and dropping duplicates (design
    /// `[...new Set([...faces, ...keys])]`).
    mutating func addFaces(_ keys: [FaceID]) {
        for k in keys where !faces.contains(k) { faces.append(k) }
    }

    /// Remove any of `keys` from this group (design `faces.filter(k => !keys.includes(k))`).
    mutating func removeFaces(_ keys: [FaceID]) {
        let drop = Set(keys)
        faces.removeAll { drop.contains($0) }
    }
}

/// The selection-groups state machine (design component `state.groups` +
/// `activeGroupId` + `nextColor` and their transitions).
public struct SelectionModel: Equatable, Sendable, Codable {
    /// The groups, in creation order (the Selections panel's row order).
    public private(set) var groups: [SelectionGroup] = []
    /// The active group new taps add to and the highlight follows (design
    /// `activeGroupId`), or nil when there is none.
    public private(set) var activeGroupID: UUID?
    /// Monotonic palette cursor (design `nextColor`): advanced by 1 whenever a group
    /// is created, so colours cycle through the palette as groups come and go.
    private var nextColor: Int = 0

    public init() {}

    /// The active group, if any.
    public var activeGroup: SelectionGroup? { groups.first { $0.id == activeGroupID } }

    /// Whether there are no groups yet (drives the panel's empty-state copy).
    public var isEmpty: Bool { groups.isEmpty }

    // MARK: - creation (design `_makeGroup` / `addGroup`)

    /// Build the next group: colour from the palette cursor, name the next letter
    /// (A, B, C…, wrapping at Z), then advance the cursor. Mirrors `_makeGroup`,
    /// which reads the *current* group count for the letter and `nextColor` for the
    /// colour, then bumps `nextColor`.
    private mutating func makeGroup() -> SelectionGroup {
        let palette = DS.Color.groupPalette
        let colorIndex = nextColor % palette.count
        let letter = Character(UnicodeScalar(UInt8(65 + (groups.count % 26))))
        nextColor += 1
        return SelectionGroup(name: "Group \(letter)", colorIndex: colorIndex)
    }

    /// The "+" button in the Selections header: create an empty group and make it
    /// active (design `addGroup`). Returns the new group's id.
    @discardableResult
    public mutating func addGroup() -> UUID {
        let g = makeGroup()
        groups.append(g)
        activeGroupID = g.id
        return g.id
    }

    // MARK: - face picking (design `_pickFace`)

    /// Toggle a single tapped face into the active group.
    public mutating func pickFace(_ key: FaceID) { pickFaces([key]) }

    /// Toggle a set of tapped faces (one face, or a whole hole's face loop) into the
    /// active group — the design's `_pickFace(keys)`:
    ///
    /// - If there is no active group, create one (auto-named/coloured) and make it
    ///   active.
    /// - If every tapped face is *already* in the active group, remove them all
    ///   (tap-again-to-deselect).
    /// - Otherwise steal those faces from any other group that holds them (a face
    ///   belongs to exactly one group) and add them to the active group.
    /// - Finally drop any now-empty group except the active one.
    public mutating func pickFaces(_ keys: [FaceID]) {
        guard !keys.isEmpty else { return }

        if activeGroup == nil {
            let g = makeGroup()
            groups.append(g)
            activeGroupID = g.id
        }
        guard let activeID = activeGroupID,
              let activeIdx = groups.firstIndex(where: { $0.id == activeID }) else { return }

        let inActive = keys.allSatisfy { groups[activeIdx].faces.contains($0) }
        if inActive {
            groups[activeIdx].removeFaces(keys)
        } else {
            for i in groups.indices where groups[i].id != activeID {
                groups[i].removeFaces(keys)
            }
            groups[activeIdx].addFaces(keys)
        }

        // Drop groups the steal/deselect emptied — but keep the active one so the
        // user can keep tapping into it (design's filter keeps `id === active.id`).
        groups.removeAll { $0.faces.isEmpty && $0.id != activeID }
    }

    /// Group-TARGETED face add for programmatic flows (the lattice page's paint
    /// pane paints into its dedicated protect group, not the active one). Steals
    /// from any other holder — a face belongs to exactly one group, the same
    /// invariant `pickFaces` keeps. Unknown id → no-op.
    public mutating func addFaces(_ keys: [FaceID], to id: UUID) {
        guard !keys.isEmpty, let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        for i in groups.indices where groups[i].id != id {
            groups[i].removeFaces(keys)
        }
        groups[idx].addFaces(keys)
        groups.removeAll { $0.faces.isEmpty && $0.id != id && $0.id != activeGroupID }
    }

    /// Group-targeted face removal (the paint pane's tap-again-to-remove). The
    /// group is KEPT when emptied — the page's paint target must survive an
    /// empty-then-repaint sequence. Unknown id → no-op.
    public mutating func removeFaces(_ keys: [FaceID], from id: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].removeFaces(keys)
    }

    // MARK: - edits (design group-row rename / select; explicit remove)

    /// Rename a group (design group-row `rename`). No-op for an unknown id.
    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = name
    }

    /// Set a group's palette colour slot (tap the group's colour swatch). Wraps into
    /// `DS.Color.groupPalette` range; no-op for an unknown id.
    public mutating func setColorIndex(_ id: UUID, _ index: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let count = DS.Color.groupPalette.count
        groups[i].colorIndex = ((index % count) + count) % count
    }

    /// Make a group active (design group-row `select`). No-op for an unknown id.
    public mutating func setActive(_ id: UUID) {
        if groups.contains(where: { $0.id == id }) { activeGroupID = id }
    }

    /// Clear the active selection so the next tapped face starts a fresh group
    /// (M7.6: committing an Anchor, or "Change" gravity, deselects — proto
    /// `S.activeId = null`). Any now-empty non-active group is dropped, matching the
    /// invariant kept by `pickFaces`.
    public mutating func clearActive() {
        activeGroupID = nil
        groups.removeAll { $0.faces.isEmpty }
    }

    /// Put regions into a group (the union commit path). A region belongs to
    /// exactly one group — the same invariant `pickFaces` keeps for faces — so
    /// this steals from any other holder.
    public mutating func addRegions(_ ids: [RegionID], to group: UUID) {
        guard !ids.isEmpty, let idx = regions_index(group) else { return }
        for i in groups.indices where groups[i].id != group {
            groups[i].removeRegions(ids)
        }
        groups[idx].addRegions(ids)
        groups.removeAll {
            $0.faces.isEmpty && $0.regionIDs.isEmpty && $0.id != group
                && $0.id != activeGroupID
        }
    }

    /// Drop regions from every group (a dissolve, or a re-import that lost them).
    public mutating func removeRegions(_ ids: [RegionID]) {
        for i in groups.indices { groups[i].removeRegions(ids) }
        groups.removeAll {
            $0.faces.isEmpty && $0.regionIDs.isEmpty && $0.id != activeGroupID
        }
    }

    /// The group that owns `region`, if any.
    public func group(forRegion region: RegionID) -> SelectionGroup? {
        groups.first { $0.regionIDs.contains(region) }
    }

    private func regions_index(_ id: UUID) -> Int? {
        groups.firstIndex(where: { $0.id == id })
    }

    /// Remove a group entirely. If it was the active group, the active selection
    /// clears (a subsequent tap starts a fresh group). No-op for an unknown id.
    public mutating func remove(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        if activeGroupID == id { activeGroupID = nil }
    }

    // MARK: - highlight lookups (drive the viewer's face colouring)

    /// The group that currently owns `face`, if any.
    public func group(forFace face: FaceID) -> SelectionGroup? {
        groups.first { $0.faces.contains(face) }
    }

    /// The colour a face should render with (its group's colour), or nil if the
    /// face is in no group.
    public func color(forFace face: FaceID) -> RGBA? { group(forFace: face)?.color }

    /// Face id → owning group id, for the whole selection (viewer highlight map).
    public var faceToGroup: [FaceID: UUID] {
        var map: [FaceID: UUID] = [:]
        for g in groups { for f in g.faces { map[f] = g.id } }
        return map
    }
}
