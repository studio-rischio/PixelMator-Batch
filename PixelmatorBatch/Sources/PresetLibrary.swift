// PresetLibrary.swift
//
// Discovers Pixelmator Pro color adjustment presets by reading its preset
// library on disk. The scripting dictionary can only *apply* a preset by
// name — it has no command to list them — so the picker is populated from
// the same plist library Pixelmator itself reads.
//
// Two libraries exist:
//   • User presets:   ~/Library/Group Containers/4R6749AYRE.com.pixelmator/
//                     Library/Application Support/com.pixelmatorteam.pixelmator.x/
//                     Presets/Adjustments.library
//   • Built-in presets: inside the app bundle under
//                     Contents/Frameworks/PXMPro.framework/Resources/Adjustments.library
//
// Each library is a folder with `collections/<uuid>.plist` (name +
// `presets-list` of preset ids) and `presets/<uuid>.plist` (name + the
// serialised adjustment data). The library's `*-LibraryInfo.plist` holds
// `collections-list`, which gives the display order.

import Foundation

struct AdjustmentPreset: Identifiable, Hashable, Sendable {
    /// Name as passed to `apply color adjustments preset … name`.
    let name: String
    /// Collection(s) this preset belongs to, in library order.
    let collections: [String]
    let isBuiltIn: Bool

    var id: String { (isBuiltIn ? "builtin:" : "user:") + name }
}

struct PresetCollection: Identifiable, Hashable, Sendable {
    let name: String
    let presets: [AdjustmentPreset]
    let isBuiltIn: Bool
    var id: String { (isBuiltIn ? "builtin:" : "user:") + name }
}

enum PresetLibrary {
    static let pixelmatorBundleID = "com.pixelmatorteam.pixelmator.x"

    static var userLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/4R6749AYRE.com.pixelmator/Library/Application Support/\(pixelmatorBundleID)/Presets/Adjustments.library", isDirectory: true)
    }

    static func builtInLibraryURL(appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/Frameworks/PXMPro.framework/Resources/Adjustments.library", isDirectory: true)
    }

    /// Loads the user's custom presets, grouped by collection. Presets that
    /// share a name are collapsed into one entry (AppleScript applies by name
    /// so they are indistinguishable at run time anyway), and the entry lists
    /// every collection the name appeared in.
    static func loadUserCollections() -> [PresetCollection] {
        load(from: userLibraryURL, builtIn: false)
    }

    static func load(from libraryURL: URL, builtIn: Bool) -> [PresetCollection] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: libraryURL.path) else {
            Log.presets.warning("preset library not found at \(libraryURL.path)")
            return []
        }

        // id -> name for every preset file.
        var presetNames: [String: String] = [:]
        let presetsDir = libraryURL.appendingPathComponent("presets", isDirectory: true)
        for url in plists(in: presetsDir) {
            if let dict = NSDictionary(contentsOf: url),
               let id = dict["id"] as? String,
               let name = dict["name"] as? String {
                presetNames[id] = name
            }
        }

        // Collections, ordered by the library info's collections-list when
        // available; collections not mentioned there go at the end.
        var order: [String] = []
        if let info = plists(in: libraryURL).first(where: { $0.lastPathComponent.hasSuffix("LibraryInfo.plist") }),
           let dict = NSDictionary(contentsOf: info),
           let list = dict["collections-list"] as? [String] {
            order = list
        }

        struct RawCollection { let id: String; let name: String; let presetIDs: [String] }
        var raw: [String: RawCollection] = [:]
        let collectionsDir = libraryURL.appendingPathComponent("collections", isDirectory: true)
        for url in plists(in: collectionsDir) {
            if let dict = NSDictionary(contentsOf: url),
               let id = dict["id"] as? String,
               let name = dict["name"] as? String {
                let ids = dict["presets-list"] as? [String] ?? []
                raw[id] = RawCollection(id: id, name: name, presetIDs: ids)
            }
        }
        let orderedIDs = order.filter { raw[$0] != nil } + raw.keys.filter { !order.contains($0) }.sorted()

        // First pass: which collections does each preset name appear in?
        var collectionsForName: [String: [String]] = [:]
        var seenInCollection: Set<String> = []
        for cid in orderedIDs {
            guard let c = raw[cid] else { continue }
            for pid in c.presetIDs {
                guard let name = presetNames[pid] else { continue }
                seenInCollection.insert(pid)
                if collectionsForName[name]?.contains(c.name) != true {
                    collectionsForName[name, default: []].append(c.name)
                }
            }
        }
        // Presets that exist on disk but aren't in any collection.
        let orphanNames = presetNames.filter { !seenInCollection.contains($0.key) }.map(\.value)
        for name in orphanNames where collectionsForName[name] == nil {
            collectionsForName[name] = ["Other"]
        }

        // Second pass: build collections, showing each name only once (in
        // the first collection it appears in).
        var emitted: Set<String> = []
        var result: [PresetCollection] = []
        for cid in orderedIDs {
            guard let c = raw[cid] else { continue }
            var presets: [AdjustmentPreset] = []
            for pid in c.presetIDs {
                guard let name = presetNames[pid], !emitted.contains(name) else { continue }
                emitted.insert(name)
                presets.append(AdjustmentPreset(name: name, collections: collectionsForName[name] ?? [c.name], isBuiltIn: builtIn))
            }
            if !presets.isEmpty {
                result.append(PresetCollection(name: c.name, presets: presets, isBuiltIn: builtIn))
            }
        }
        let orphans = orphanNames.filter { !emitted.contains($0) }.sorted()
        if !orphans.isEmpty {
            result.append(PresetCollection(
                name: "Other",
                presets: orphans.map { AdjustmentPreset(name: $0, collections: ["Other"], isBuiltIn: builtIn) },
                isBuiltIn: builtIn
            ))
        }

        let total = result.reduce(0) { $0 + $1.presets.count }
        Log.presets.info("loaded \(total) \(builtIn ? "built-in" : "user") presets in \(result.count) collections from \(libraryURL.path) (\(presetNames.count) preset files)")
        return result
    }

    private static func plists(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
}
