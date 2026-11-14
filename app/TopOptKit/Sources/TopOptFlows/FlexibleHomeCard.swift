// FlexibleHomeCard — round 7 · U21, batch A: the Home card of a Flexible project names its filament, not "ABS".
//
// The reviewer's ruling of 2026-10-22 06:38 (1): "HOME CARD: a Flexible project must NOT read "ABS" … approved in principle:
// show the Flexible filament when lattice.flexible.materialID is set, today's label otherwise." Main's HomeView carries one
// hook (H46): `Text(FlexibleHomeCard.meta(project) ?? project.meta)`. nil ⇒ today's `project.meta`, so a Topology project's
// card is untouched.
//
// READ-ONLY: the saved project.json under the project store's folder is read (never written), and only
// `lattice.flexible.materialID` is decoded. Cached by project id + the file's modification date, so a card re-reads only after
// a save.

import Foundation
import TopOptKit

@MainActor
public enum FlexibleHomeCard {

    /// Tests only: the store folder (nil ⇒ the app's own `ProjectStore().rootDir`) and the filament list (nil ⇒ the bundle's).
    nonisolated(unsafe) static var testStoreRoot: URL?
    nonisolated(unsafe) static var testMaterialsPath: String?

    private struct Snap: Decodable {
        struct Lattice: Decodable {
            struct Flexible: Decodable { let materialID: String? }
            let flexible: Flexible?
        }
        let lattice: Lattice?
    }
    private static var cache: [UUID: (date: Date, id: String?)] = [:]
    private static var names: [String: String]?
    /// How many times a project.json was read (the cache's test).
    static var reads = 0

    private static var root: URL { testStoreRoot ?? ProjectStore().rootDir }

    /// "<filament short name> · Just now" for a project whose saved Flexible setup has a filament; nil otherwise.
    public static func meta(_ project: RecentProject) -> String? {
        guard let id = materialID(project.id) else { return nil }
        return "\(name(id)) · Just now"
    }

    static func materialID(_ id: UUID) -> String? {
        let url = root.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("project.json")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        if let c = cache[id], c.date == date { return c.id }
        reads += 1
        let m = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Snap.self, from: $0) }?.lattice?.flexible?.materialID
        cache[id] = (date, m)
        return m
    }

    /// The Model card's short name ("colorFabb varioShore TPU"); the id itself if the list is missing.
    static func name(_ id: String) -> String {
        if names == nil {
            let path = testMaterialsPath ?? FlexibleResources.materialsPath
            let list = path.flatMap { try? FlexibleCore.materials(path: $0) } ?? []
            names = Dictionary(list.map { ($0.id, FlexibleRowCopy.shortName($0.displayName)) }, uniquingKeysWith: { a, _ in a })
        }
        return names?[id] ?? id
    }

    static func resetForTests() { cache = [:]; names = nil; reads = 0 }
}
