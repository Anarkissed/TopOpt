// PrintParamsPresetStore.swift — cross-launch persistence for app-wide print
// presets (the M7.params "save named preset" feature).
//
// A deliberately tiny sibling of `ProjectStore`: presets are APP-level, not
// per-project, so they live in ONE file next to (not inside) the per-project
// folders — `<AppSupport>/TopOpt/print-presets.json`. Keeping them out of the
// `Projects/` tree is what makes a preset "available to all projects": deleting a
// project never touches them. Pure filesystem with an injectable root so it is
// unit-tested against a temp directory; `AppModel` owns the in-memory list.

import Foundation

/// Reads/writes the user's saved print-parameter presets as a single JSON file.
public struct PrintParamsPresetStore {
    /// The presets file (`<root>/print-presets.json`).
    public let fileURL: URL
    private let fm = FileManager.default

    /// - Parameter rootDir: base directory. Defaults to `<AppSupport>/TopOpt`;
    ///   tests pass a temp directory. The presets file sits directly under it, a
    ///   sibling of the `Projects/` folder `ProjectStore` uses.
    public init(rootDir: URL? = nil) {
        let base: URL
        if let rootDir {
            base = rootDir
        } else {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                        in: .userDomainMask,
                                                        appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            base = support.appendingPathComponent("TopOpt", isDirectory: true)
        }
        self.fileURL = base.appendingPathComponent("print-presets.json")
    }

    /// The saved presets in stored order, or an empty list when none are saved yet /
    /// the file is unreadable. The built-in "Default" is NOT here (it's synthesized).
    public func load() -> [PrintParamsPreset] {
        guard let data = try? Data(contentsOf: fileURL),
              let presets = try? JSONDecoder().decode([PrintParamsPreset].self, from: data)
        else { return [] }
        return presets
    }

    /// Overwrite the stored presets with `presets`. Creates the directory on first
    /// save. Throws on a filesystem/encode error so the caller can surface it.
    public func save(_ presets: [PrintParamsPreset]) throws {
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(presets)
        try data.write(to: fileURL, options: .atomic)
    }
}
