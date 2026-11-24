// LatticeSampleKeep.swift — ★ his iPad notes 2026-11-23 evening (img 3, img 9: Lattice settings, the rail's Part / Front face /
// Back Wall): "Surely it should be saved so that it is an instant switch when I tap on the other group, before any changes are
// made." Every tap on another group rebuilt that group's sample from nothing (an Organic one took seconds).
//
// The last sample built for each group is kept, with the inputs it was built from (`LatticeSampleView.Inputs`: everything the
// sample is made of — the type, cell, densities, Organic settings, the printer's line and layer). Back on a group whose inputs
// are what its kept sample was built from, the sample shows at once, with no build; any change builds as before, and the new
// sample replaces the kept one. Memory: one sample per group and view (Cells, In a part) of the OPEN part, at most
// `maxKept` in all (the least recently shown goes first); all of them go when the part closes (`AppModel.backHome`) or
// another part's page asks.

import Foundation

@MainActor
final class LatticeSampleKeep {
    static let shared = LatticeSampleKeep()

    /// Which group's sample: the open part, the page's tab ("part", "area-0", …).
    struct Key: Equatable {
        var project: UUID
        var group: String
    }

    /// A sample as it was shown: its body, the Organic struts drawn in it (nil: a strut type's sample), its caption and how
    /// long it took.
    struct Sample {
        var mesh: ViewerMesh
        var bars: LatticeLayoutBarsInputs?
        var caption: String
        var seconds: Double?
    }

    /// At most this many kept samples (a group's Cells and In a part are two).
    static let maxKept = 6

    private struct Entry {
        var key: Key
        var shape: LatticeSampleView.Shape
        var inputs: LatticeSampleView.Inputs
        var sample: Sample
    }
    /// Least recently shown first.
    private var entries: [Entry] = []

    /// How many samples are kept now (tests).
    var count: Int { entries.count }

    /// The kept sample for `key`, if it was built from exactly `inputs`; it becomes the most recently shown.
    func sample(_ key: Key, for inputs: LatticeSampleView.Inputs) -> Sample? {
        forgetOtherParts(than: key.project)
        guard let i = entries.firstIndex(where: { $0.key == key && $0.shape == inputs.shape }),
              entries[i].inputs == inputs else { return nil }
        let e = entries.remove(at: i)
        entries.append(e)
        return e.sample
    }

    /// Keep `sample`, built from `inputs`, as `key`'s (it replaces that group's last one).
    func keep(_ key: Key, inputs: LatticeSampleView.Inputs, _ sample: Sample) {
        forgetOtherParts(than: key.project)
        entries.removeAll { $0.key == key && $0.shape == inputs.shape }
        entries.append(Entry(key: key, shape: inputs.shape, inputs: inputs, sample: sample))
        if entries.count > Self.maxKept { entries.removeFirst(entries.count - Self.maxKept) }
    }

    /// The part closed: every kept sample goes.
    func forget() { entries.removeAll() }

    private func forgetOtherParts(than project: UUID) {
        entries.removeAll { $0.key.project != project }
    }
}
