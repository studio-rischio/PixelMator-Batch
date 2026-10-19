// BatchProcessor.swift
//
// Owns one batch run: iterates the scanned files, hands each to
// PixelmatorBridge on a background task, and publishes progress for the UI.
// Exports land in a temp file next to the destination and are swapped in
// atomically once Pixelmator reports success, so a crash or cancel mid-export
// never leaves a half-written image where the original (or a previous
// export) used to be.

import Foundation

/// How to treat destination files that already exist. Decided by the user in
/// the pre-run confirmation dialog.
enum ConflictPolicy: String, Sendable {
    case overwrite, skipExisting
}

struct BatchJob: Sendable {
    let files: [URL]
    let preset: AdjustmentPreset
    /// nil means overwrite originals in place.
    let outputFolder: URL?
    let jpegQuality: Int
    let conflictPolicy: ConflictPolicy

    var overwritesOriginals: Bool { outputFolder == nil }

    func destination(for file: URL) -> URL {
        outputFolder?.appendingPathComponent(file.lastPathComponent) ?? file
    }

    /// Files whose destination already exists. In overwrite mode that is
    /// every file; in export mode it is whatever a previous run left behind.
    func existingDestinations() -> [URL] {
        files.map(destination(for:)).filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct BatchFailure: Identifiable, Sendable {
    let id = UUID()
    let file: URL
    let message: String
}

struct BatchSummary: Sendable {
    let processed: Int
    let skipped: Int
    let failures: [BatchFailure]
    let cancelled: Bool
    let total: Int
    let duration: TimeInterval
    /// Folder to reveal from the summary dialog.
    let outputFolder: URL
}

@MainActor
@Observable
final class BatchProcessor {
    enum Phase: Equatable {
        case idle
        case launching
        case running
        case cancelling
    }

    private(set) var phase: Phase = .idle
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var currentFileName: String = ""
    private(set) var summary: BatchSummary?

    var isBusy: Bool { phase != .idle }
    var fractionComplete: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var worker: Task<Void, Never>?

    func start(_ job: BatchJob) {
        guard phase == .idle else { return }
        summary = nil
        cancelRequested = false
        completed = 0
        total = job.files.count
        currentFileName = ""
        phase = .launching

        Log.export.info("batch start: \(job.files.count) files, preset \"\(job.preset.name)\", \(job.overwritesOriginals ? "overwrite originals" : "output → \(job.outputFolder!.path)"), jpeg quality \(job.jpegQuality), conflicts: \(job.conflictPolicy.rawValue)")

        worker = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            var processed = 0, skipped = 0
            var failures: [BatchFailure] = []

            do {
                try await PixelmatorBridge.launch()
            } catch {
                Log.pixelmator.error("launch failed: \(error.localizedDescription)")
                finish(BatchSummary(processed: 0, skipped: 0,
                                    failures: [BatchFailure(file: job.files.first ?? URL(fileURLWithPath: "/"), message: error.localizedDescription)],
                                    cancelled: false, total: job.files.count, duration: 0,
                                    outputFolder: job.outputFolder ?? job.files.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory())))
                return
            }

            if let out = job.outputFolder {
                do {
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                } catch {
                    Log.export.error("could not create output folder \(out.path): \(error.localizedDescription)")
                }
            }

            phase = .running

            for file in job.files {
                if cancelRequested {
                    Log.export.warning("batch cancelled by user after \(completed) of \(total)")
                    break
                }
                currentFileName = file.lastPathComponent
                let dest = job.destination(for: file)

                if !job.overwritesOriginals,
                   job.conflictPolicy == .skipExisting,
                   FileManager.default.fileExists(atPath: dest.path) {
                    skipped += 1
                    completed += 1
                    Log.export.info("skip (exists): \(dest.lastPathComponent)")
                    continue
                }

                let format = ExportFormat(normalizedType: ImageScan.normalizedType(for: file))
                let temp = dest.deletingLastPathComponent()
                    .appendingPathComponent("\(dest.deletingPathExtension().lastPathComponent).pixelmatorbatch-tmp.\(dest.pathExtension)")
                let preset = job.preset.name
                let quality = job.jpegQuality

                Log.pixelmator.info("process \(file.lastPathComponent) → \(dest.path) as \(format.rawValue)")
                let t0 = Date()
                let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        try PixelmatorBridge.process(input: file, tempOutput: temp, preset: preset, format: format, quality: quality)
                        try Self.swapIntoPlace(temp: temp, destination: dest)
                        return .success(())
                    } catch {
                        try? FileManager.default.removeItem(at: temp)
                        return .failure(error)
                    }
                }.value

                switch result {
                case .success:
                    processed += 1
                    Log.export.info("done \(dest.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                case .failure(let error):
                    failures.append(BatchFailure(file: file, message: error.localizedDescription))
                    Log.export.error("failed \(file.lastPathComponent): \(error.localizedDescription)")
                }
                completed += 1
            }

            let outputFolder = job.outputFolder ?? job.files.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory())
            finish(BatchSummary(processed: processed, skipped: skipped, failures: failures,
                                cancelled: cancelRequested, total: job.files.count,
                                duration: Date().timeIntervalSince(started), outputFolder: outputFolder))
        }
    }

    /// Cancel takes effect after the image currently inside Pixelmator Pro
    /// finishes — interrupting mid-export would leave a stray document open
    /// in Pixelmator, and the atomic swap means nothing is half-written.
    func cancel() {
        guard phase == .running || phase == .launching else { return }
        cancelRequested = true
        phase = .cancelling
        Log.ui.info("cancel requested; finishing current image")
    }

    private func finish(_ s: BatchSummary) {
        summary = s
        phase = .idle
        currentFileName = ""
        Log.export.info("batch finished: processed \(s.processed), skipped \(s.skipped), failed \(s.failures.count), cancelled \(s.cancelled), \(String(format: "%.1f", s.duration))s")
    }

    nonisolated private static func swapIntoPlace(temp: URL, destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }
}
