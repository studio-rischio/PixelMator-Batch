// PixelmatorBridge.swift
//
// Drives Pixelmator Pro over Apple Events. Each image is processed by one
// `osascript` run so the work happens off the main thread (NSAppleScript is
// main-thread only) and a wedged export can be killed without taking the app
// down with it. The script opens the file, applies the chosen color
// adjustments preset to the first layer, exports to a temp file beside the
// destination, and closes the document without saving. The caller then
// atomically swaps the temp file into place — this is what makes
// "overwrite originals" safe: the original is only replaced once the export
// finished successfully.
//
// Sandbox detour: Pixelmator Pro is sandboxed, and whether it can read a file
// named in an Apple Event depends on the *sender's* privileges — from a
// terminal with Full Disk Access it opens anything, from this app it fails on
// Desktop/Documents/Downloads with "Operation not permitted" (and `open`
// returns `missing value`). Pixelmator does hold the
// com.apple.security.assets.pictures.read-write entitlement, so every image is
// staged through a hidden folder in ~/Pictures: the input is cloned in
// (instant on APFS), Pixelmator reads and exports there, and the result is
// moved to its real destination afterwards.
//
// Known Pixelmator Pro behaviour (verified against 3.8):
//   • `open` returns `missing value` instead of erroring when it cannot read
//     the file (sandbox-inaccessible paths). We check for that.
//   • `apply color adjustments preset` silently accepts unknown names.
//   • `export` honours the `as` format; `compression factor` applies to
//     JPEG, HEIC and WebP only.

import Foundation
import AppKit

enum ExportFormat: String, Sendable {
    case jpeg = "JPEG", png = "PNG", tiff = "TIFF", heic = "HEIC", webp = "WebP"

    /// Map from `ImageScan.normalizedType` to Pixelmator's export enumerator.
    init(normalizedType: String) {
        switch normalizedType {
        case "png":  self = .png
        case "tiff": self = .tiff
        case "heic": self = .heic
        case "webp": self = .webp
        default:     self = .jpeg
        }
    }

    var usesCompressionFactor: Bool {
        switch self {
        case .jpeg, .heic, .webp: true
        case .png, .tiff: false
        }
    }
}

struct PixelmatorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum PixelmatorBridge {
    static let bundleID = PresetLibrary.pixelmatorBundleID

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var isInstalled: Bool { appURL != nil }

    /// Launch (or bring forward) Pixelmator Pro. Apple Events would launch it
    /// implicitly, but doing it up front gives a clearer log line and lets the
    /// first `open` go through without eating the launch time.
    @MainActor
    static func launch() async throws {
        guard let url = appURL else {
            throw PixelmatorError(message: "Pixelmator Pro is not installed.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        Log.pixelmator.info("launched Pixelmator Pro at \(url.path)")
    }

    /// Hidden staging root inside ~/Pictures (see the sandbox note above).
    static var stagingRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/.Pixelmator Batch Staging", isDirectory: true)
    }

    /// Remove staging folders left behind by a crash or force-quit. Only one
    /// image is ever in flight, so this is at most one folder — but it lives
    /// in a hidden directory nobody would find. Called once at launch; the
    /// per-image `defer` handles the normal case.
    static func sweepStaging() {
        let fm = FileManager.default
        guard let leftovers = try? fm.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil),
              !leftovers.isEmpty else { return }
        for url in leftovers {
            do {
                try fm.removeItem(at: url)
                Log.pixelmator.warning("removed stale staging folder \(url.lastPathComponent)")
            } catch {
                Log.pixelmator.error("could not remove stale staging folder \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// Process one image. Blocks the calling thread until osascript exits —
    /// call from a background Task. Writes to `tempOutput`; the caller moves it.
    static func process(
        input: URL,
        tempOutput: URL,
        preset: String,
        format: ExportFormat,
        quality: Int,
        timeoutSeconds: Int = 600
    ) throws {
        let fm = FileManager.default
        let stage = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stageOut = stage.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: stageOut, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        let stagedIn = stage.appendingPathComponent(input.lastPathComponent)
        let stagedOut = stageOut.appendingPathComponent(input.lastPathComponent)
        try fm.copyItem(at: input, to: stagedIn)

        try runScript(input: stagedIn, output: stagedOut, preset: preset, format: format,
                      quality: quality, timeoutSeconds: timeoutSeconds)

        guard fm.fileExists(atPath: stagedOut.path) else {
            throw PixelmatorError(message: "Pixelmator Pro reported success but no file was written.")
        }
        try? fm.removeItem(at: tempOutput)
        try fm.moveItem(at: stagedOut, to: tempOutput)
    }

    private static func runScript(
        input: URL,
        output: URL,
        preset: String,
        format: ExportFormat,
        quality: Int,
        timeoutSeconds: Int
    ) throws {
        let script = """
        on run argv
            set inPath to item 1 of argv
            set outPath to item 2 of argv
            set presetName to item 3 of argv
            set fmt to item 4 of argv
            set q to (item 5 of argv) as integer
            tell application "Pixelmator Pro"
                with timeout of \(timeoutSeconds) seconds
                    set doc to open (POSIX file inPath)
                    if doc is missing value then error "Pixelmator Pro could not open the file (no document returned)." number 9001
                    try
                        apply color adjustments preset (first layer of doc) name presetName
                        -- `POSIX file` must stay inline: stored in a variable inside this
                        -- tell block it becomes an object specifier Pixelmator tries to
                        -- resolve and fails with "Can't get POSIX file …" (-1728).
                        if fmt is "PNG" then
                            export doc to (POSIX file outPath) as PNG
                        else if fmt is "TIFF" then
                            export doc to (POSIX file outPath) as TIFF
                        else if fmt is "HEIC" then
                            export doc to (POSIX file outPath) as HEIC with properties {compression factor:q}
                        else if fmt is "WebP" then
                            export doc to (POSIX file outPath) as WebP with properties {compression factor:q}
                        else
                            export doc to (POSIX file outPath) as JPEG with properties {compression factor:q}
                        end if
                    on error msg number n
                        try
                            close doc without saving
                        end try
                        error msg number n
                    end try
                    close doc without saving
                end timeout
            end tell
        end run
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-", input.path, output.path, preset, format.rawValue, String(quality)]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try? stdin.fileHandleForWriting.close()

        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if proc.terminationReason == .uncaughtSignal {
            throw PixelmatorError(message: "Cancelled while processing.")
        }
        guard proc.terminationStatus == 0 else {
            throw PixelmatorError(message: cleaned(errText).isEmpty ? "osascript exited with status \(proc.terminationStatus)" : cleaned(errText))
        }
    }

    /// osascript prefixes errors with "<script>:<range>: execution error: ".
    /// Strip that so the log reads as Pixelmator's own message.
    private static func cleaned(_ s: String) -> String {
        if let r = s.range(of: "execution error: ") { return String(s[r.upperBound...]) }
        return s
    }
}
