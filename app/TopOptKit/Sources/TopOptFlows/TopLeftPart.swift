// TopLeftPart — ★ notes27 (G3, his 11-24 ~00:20): "Instead of "Squish Mechanism" being the only exit, can you add another button
// to the right of that called "Part" that leads to the list of the versions of the part rather than all the way back to the
// project? Connect it like Structural | Setup | Lattice... etc., making it part of the same pill, but separated with a "|"."
//
// The top-left block's back pill is "‹ the project | Part" (TopLeftBlock). Part is Back (`AppModel.backHome`: the version kept,
// the Library refreshed) landing on the part's own page — its versions, where "Open v8" is — instead of its project's folder.
// Before he groups there is no part's page, and no Part.
import Foundation

extension LibraryModel {
    /// The part's page for the version in `folder` (the part's id), or nil before he groups.
    func partPage(of folder: UUID) -> UUID? {
        guard mode == .library else { return nil }
        return index.part(containing: folder)?.id
    }

    /// Back lands on the part's page (its versions) rather than its project (`comeBack`).
    func comeBackToPart(from folder: UUID) {
        if let id = partPage(of: folder) { route = .part(id) }
    }
}

extension AppModel {
    /// ★ notes27 (G3): "Part" — Back, landing on this part's versions.
    public func backToPart() {
        let folder = project?.id
        backHome()
        if let folder { library.comeBackToPart(from: folder) }
    }
}
