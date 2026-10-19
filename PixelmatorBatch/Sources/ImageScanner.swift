// ImageScanner.swift
//
// Enumerates the top level of a folder (no recursion, by design) for image
// files Pixelmator Pro can open and we can round-trip through `export`.

import Foundation

struct ImageScan: Sendable {
    let folder: URL
    let files: [URL]
    let totalBytes: Int64
    /// Normalised extension -> count (jpeg folded into jpg, tif into tiff).
    let typeCounts: [String: Int]

    var count: Int { files.count }
    var typeCount: Int { typeCounts.count }

    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "webp"]

    static func normalizedType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpeg": "jpg"
        case "tif":  "tiff"
        case let e:  e
        }
    }

    /// Scan runs on whatever thread calls it; the UI wraps it in a Task.
    static func scan(folder: URL) throws -> ImageScan {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isHiddenKey]
        let contents = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var files: [URL] = []
        var bytes: Int64 = 0
        var types: [String: Int] = [:]
        for url in contents {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            files.append(url)
            bytes += Int64(values?.fileSize ?? 0)
            types[normalizedType(for: url), default: 0] += 1
        }
        files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        Log.scan.info("scanned \(folder.path): \(files.count) images, \(types.count) types, \(bytes) bytes")
        return ImageScan(folder: folder, files: files, totalBytes: bytes, typeCounts: types)
    }
}
