// ContentView.swift
//
// Main window: source/output selection on the left, preset picker on the
// right, progress bar with Start/Cancel along the bottom. Confirmation and
// summary dialogs are driven from here too.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var processor = BatchProcessor()

    // Source
    @State private var sourceFolder: URL?
    @State private var scan: ImageScan?
    @State private var scanError: String?
    @State private var isScanning = false
    @State private var isDropTargeted = false

    // Output
    @State private var outputFolder: URL?
    @AppStorage("overwriteOriginals") private var overwriteOriginals = false
    @AppStorage("jpegQuality") private var jpegQuality = 90

    // Presets
    @State private var collections: [PresetCollection] = []
    @AppStorage("selectedPresetID") private var selectedPresetID: String = ""
    @State private var presetSearch = ""

    // Dialogs
    @State private var pendingJob: BatchJob?
    @State private var pendingConflicts: [URL] = []
    @State private var showOverwriteOriginalsConfirm = false
    @State private var showOutputConflictConfirm = false
    @State private var showSummary = false
    @State private var validationMessage: String?

    private let pixelmatorInstalled = PixelmatorBridge.isInstalled

    private var selectedPreset: AdjustmentPreset? {
        collections.flatMap(\.presets).first { $0.id == selectedPresetID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !pixelmatorInstalled {
                notInstalledBanner
            }
            HSplitView {
                sourcePane
                    .frame(minWidth: 380, idealWidth: 440)
                presetPane
                    .frame(minWidth: 300, idealWidth: 380)
            }
            Divider()
            bottomBar
        }
        .onAppear(perform: reloadPresets)
        .onChange(of: processor.summary != nil) { _, hasSummary in
            if hasSummary { showSummary = true }
        }
        .alert("Overwrite original images?", isPresented: $showOverwriteOriginalsConfirm, presenting: pendingJob) { job in
            Button("Overwrite \(job.files.count) Originals", role: .destructive) { run(job, policy: .overwrite) }
            Button("Cancel", role: .cancel) { Log.ui.info("overwrite originals: cancelled"); pendingJob = nil }
        } message: { job in
            Text("The preset “\(job.preset.name)” will be applied to \(job.files.count) image\(job.files.count == 1 ? "" : "s") in “\(job.files.first?.deletingLastPathComponent().lastPathComponent ?? "")” and the originals will be replaced. This cannot be undone.")
        }
        .alert("Some files already exist", isPresented: $showOutputConflictConfirm, presenting: pendingJob) { job in
            Button("Overwrite All", role: .destructive) { run(job, policy: .overwrite) }
            Button("Skip Existing") { run(job, policy: .skipExisting) }
            Button("Cancel", role: .cancel) { Log.ui.info("output conflicts: cancelled"); pendingJob = nil }
        } message: { job in
            Text("\(pendingConflicts.count) of \(job.files.count) image\(job.files.count == 1 ? "" : "s") already exist in “\(job.outputFolder?.lastPathComponent ?? "")”. Overwrite them, or skip the ones that already exist?")
        }
        .alert("Can’t start", isPresented: Binding(get: { validationMessage != nil }, set: { if !$0 { validationMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
        .sheet(isPresented: $showSummary) {
            if let s = processor.summary {
                SummaryView(summary: s) { showSummary = false }
            }
        }
    }

    // MARK: - Left pane

    private var sourcePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Source") {
                    VStack(alignment: .leading, spacing: 10) {
                        dropZone
                        HStack {
                            Button("Choose Folder…") { chooseSourceFolder() }
                                .disabled(processor.isBusy)
                            if sourceFolder != nil {
                                Button("Rescan") { rescan() }
                                    .disabled(processor.isBusy || isScanning)
                            }
                            Spacer()
                        }
                        scanSummary
                    }
                    .padding(6)
                }

                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $overwriteOriginals) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Overwrite originals")
                                Text("Replace each source image in place instead of exporting to a separate folder.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(processor.isBusy)
                        .onChange(of: overwriteOriginals) { _, on in
                            Log.ui.info("overwrite originals: \(on ? "on" : "off")")
                        }

                        HStack(alignment: .firstTextBaseline) {
                            Text("Folder:").frame(width: 56, alignment: .trailing)
                            Text(outputFolder?.path(percentEncoded: false) ?? "Not set")
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(outputFolder == nil ? .secondary : .primary)
                                .help(outputFolder?.path(percentEncoded: false) ?? "")
                            Spacer()
                            Button("Choose…") { chooseOutputFolder() }
                        }
                        .disabled(overwriteOriginals || processor.isBusy)
                        .opacity(overwriteOriginals ? 0.5 : 1)

                        HStack(alignment: .firstTextBaseline) {
                            Text("JPEG quality:").frame(alignment: .trailing)
                            Slider(value: Binding(get: { Double(jpegQuality) }, set: { jpegQuality = Int($0.rounded()) }), in: 1...100, step: 1)
                                .frame(maxWidth: 220)
                                .onChange(of: jpegQuality) { _, q in Log.ui.debug("jpeg quality: \(q)") }
                            Text("\(jpegQuality)").monospacedDigit().frame(width: 32, alignment: .trailing)
                            Button("Reset") { jpegQuality = 90 }
                                .controlSize(.small)
                                .disabled(jpegQuality == 90)
                        }
                        .disabled(processor.isBusy)
                        Text("Applies to JPEG, HEIC and WebP exports. PNG and TIFF are lossless.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
            }
            .padding(16)
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 10).fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
            VStack(spacing: 6) {
                Image(systemName: sourceFolder == nil ? "folder.badge.plus" : "folder.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                if let f = sourceFolder {
                    Text(f.lastPathComponent).font(.headline).lineLimit(1)
                    Text(f.deletingLastPathComponent().path(percentEncoded: false))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Drop a folder of photos here").font(.headline)
                    Text("or use Choose Folder… below").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(height: 120)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .allowsHitTesting(!processor.isBusy)
    }

    @ViewBuilder
    private var scanSummary: some View {
        if isScanning {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…").foregroundStyle(.secondary) }
        } else if let err = scanError {
            Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if let s = scan {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow { Text("Images").foregroundStyle(.secondary); Text("\(s.count)").monospacedDigit() }
                GridRow {
                    Text("Types").foregroundStyle(.secondary)
                    Text(typeSummary(s)).monospacedDigit()
                }
                GridRow { Text("Size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: s.totalBytes, countStyle: .file)) }
            }
            .font(.callout)
            if s.count == 0 {
                Text("No supported images at the top level of this folder. Supported: JPEG, PNG, TIFF, HEIC, WebP.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Top-level files only. Subfolders are not scanned.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func typeSummary(_ s: ImageScan) -> String {
        let parts = s.typeCounts.sorted { $0.value > $1.value }.map { "\($0.key.uppercased()) \($0.value)" }
        return "\(s.typeCount)" + (parts.isEmpty ? "" : "  (\(parts.joined(separator: ", ")))")
    }

    // MARK: - Right pane

    private var presetPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Color Adjustment Presets").font(.headline)
                Spacer()
                Button {
                    reloadPresets()
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Re-read the preset library from disk")
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter presets…", text: $presetSearch)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)

            if collections.isEmpty {
                ContentUnavailableView {
                    Label("No presets found", systemImage: "slider.horizontal.3")
                } description: {
                    Text("Save a color adjustments preset in Pixelmator Pro, then click refresh.")
                }
            } else {
                List(selection: $selectedPresetID) {
                    ForEach(filteredCollections) { c in
                        Section(c.name) {
                            ForEach(c.presets) { p in
                                HStack {
                                    Text(p.name)
                                    Spacer()
                                    if p.collections.count > 1 {
                                        Text("in \(p.collections.count) collections")
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                .tag(p.id)
                            }
                        }
                    }
                }
                .onChange(of: selectedPresetID) { _, id in
                    if let p = collections.flatMap(\.presets).first(where: { $0.id == id }) {
                        Log.ui.info("preset selected: \"\(p.name)\"")
                    }
                }
                .disabled(processor.isBusy)
            }

            Divider()
            HStack {
                let total = collections.reduce(0) { $0 + $1.presets.count }
                Text("\(total) preset\(total == 1 ? "" : "s") from your Pixelmator Pro library")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
    }

    private var filteredCollections: [PresetCollection] {
        let q = presetSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return collections }
        return collections.compactMap { c in
            let hits = c.presets.filter { $0.name.lowercased().contains(q) }
            return hits.isEmpty ? nil : PresetCollection(name: c.name, presets: hits, isBuiltIn: c.isBuiltIn)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if processor.phase == .launching {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: processor.fractionComplete)
                        .progressViewStyle(.linear)
                        .animation(.easeInOut(duration: 0.3), value: processor.fractionComplete)
                }
                Text(statusLine)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .monospacedDigit()
            }
            Button("Cancel") {
                processor.cancel()
            }
            .disabled(processor.phase != .running && processor.phase != .launching)
            Button("Start") { startTapped() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(processor.isBusy || !pixelmatorInstalled)
        }
        .padding(14)
    }

    private var statusLine: String {
        switch processor.phase {
        case .idle:
            if let s = processor.summary {
                return "Last run: \(s.processed) processed, \(s.skipped) skipped, \(s.failures.count) failed\(s.cancelled ? " (cancelled)" : "")"
            }
            return "Ready"
        case .launching:
            return "Launching Pixelmator Pro…"
        case .running:
            return "\(processor.completed) of \(processor.total) · \(processor.currentFileName)"
        case .cancelling:
            return "Cancelling after \(processor.currentFileName)…"
        }
    }

    private var notInstalledBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Pixelmator Pro is not installed. This app drives Pixelmator Pro over AppleScript and cannot run without it.")
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }

    // MARK: - Actions

    private func reloadPresets() {
        collections = PresetLibrary.loadUserCollections()
        let all = collections.flatMap(\.presets)
        if !all.contains(where: { $0.id == selectedPresetID }) {
            selectedPresetID = all.first?.id ?? ""
        }
        Log.ui.info("presets reloaded: \(all.count) available, selected \"\(selectedPreset?.name ?? "none")\"")
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder containing the photos to process."
        if let s = sourceFolder { panel.directoryURL = s.deletingLastPathComponent() }
        Log.ui.info("choose source folder: panel shown")
        if panel.runModal() == .OK, let url = panel.url {
            setSource(url)
        } else {
            Log.ui.info("choose source folder: cancelled")
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where exported images should be written."
        if let o = outputFolder { panel.directoryURL = o }
        Log.ui.info("choose output folder: panel shown")
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            Log.ui.info("output folder set: \(url.path)")
        } else {
            Log.ui.info("choose output folder: cancelled")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard var url else { return }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if !isDir.boolValue {
                // A file was dropped — use its enclosing folder.
                url = url.deletingLastPathComponent()
            }
            let folder = url
            Task { @MainActor in
                Log.ui.info("drop: \(isDir.boolValue ? "folder" : "file (using parent)") \(folder.path)")
                setSource(folder)
            }
        }
        return true
    }

    private func setSource(_ url: URL) {
        sourceFolder = url
        Log.ui.info("source folder set: \(url.path)")
        if outputFolder == nil {
            outputFolder = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) Edited", isDirectory: true)
            Log.ui.info("output folder defaulted: \(outputFolder!.path)")
        }
        rescan()
    }

    private func rescan() {
        guard let folder = sourceFolder else { return }
        isScanning = true
        scanError = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try ImageScan.scan(folder: folder) }
            await MainActor.run {
                switch result {
                case .success(let s): scan = s
                case .failure(let e):
                    scan = nil
                    scanError = e.localizedDescription
                    Log.scan.error("scan failed for \(folder.path): \(e.localizedDescription)")
                }
                isScanning = false
            }
        }
    }

    private func startTapped() {
        Log.ui.info("start tapped")
        guard let scan, scan.count > 0 else {
            validationMessage = "Choose a folder that contains at least one supported image."
            Log.ui.warning("start blocked: no images")
            return
        }
        guard let preset = selectedPreset else {
            validationMessage = "Select a color adjustments preset."
            Log.ui.warning("start blocked: no preset")
            return
        }
        let output: URL?
        if overwriteOriginals {
            output = nil
        } else {
            guard let o = outputFolder else {
                validationMessage = "Choose an output folder, or turn on “Overwrite originals”."
                Log.ui.warning("start blocked: no output folder")
                return
            }
            if o.standardizedFileURL == scan.folder.standardizedFileURL {
                validationMessage = "The output folder is the same as the source folder. Choose a different folder, or turn on “Overwrite originals” to replace the files in place."
                Log.ui.warning("start blocked: output == source")
                return
            }
            output = o
        }

        let job = BatchJob(files: scan.files, preset: preset, outputFolder: output, jpegQuality: jpegQuality, conflictPolicy: .overwrite)
        pendingJob = job
        if job.overwritesOriginals {
            Log.ui.info("confirm: overwrite \(job.files.count) originals")
            showOverwriteOriginalsConfirm = true
            return
        }
        let conflicts = job.existingDestinations()
        if conflicts.isEmpty {
            run(job, policy: .overwrite)
        } else {
            pendingConflicts = conflicts
            Log.ui.info("confirm: \(conflicts.count) of \(job.files.count) already exist in output")
            showOutputConflictConfirm = true
        }
    }

    private func run(_ base: BatchJob, policy: ConflictPolicy) {
        pendingJob = nil
        let job = BatchJob(files: base.files, preset: base.preset, outputFolder: base.outputFolder, jpegQuality: base.jpegQuality, conflictPolicy: policy)
        Log.ui.info("confirmed: \(policy.rawValue)")
        processor.start(job)
    }
}

// MARK: - Summary sheet

private struct SummaryView: View {
    let summary: BatchSummary
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(summary.failures.isEmpty && !summary.cancelled ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3).fontWeight(.semibold)
                    Text(String(format: "Finished in %.1f seconds", summary.duration))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Processed").foregroundStyle(.secondary); Text("\(summary.processed)") }
                if summary.skipped > 0 {
                    GridRow { Text("Skipped").foregroundStyle(.secondary); Text("\(summary.skipped)") }
                }
                if !summary.failures.isEmpty {
                    GridRow { Text("Failed").foregroundStyle(.secondary); Text("\(summary.failures.count)") }
                }
                GridRow { Text("Total").foregroundStyle(.secondary); Text("\(summary.total)") }
            }
            .monospacedDigit()

            if !summary.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.failures) { f in
                            Text("\(f.file.lastPathComponent): \(f.message)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: 120)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Close") { Log.ui.info("summary: closed"); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Output Folder") {
                    Log.ui.info("summary: open output folder \(summary.outputFolder.path)")
                    NSWorkspace.shared.open(summary.outputFolder)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { Log.ui.info("summary shown") }
    }

    private var title: String {
        if summary.cancelled { return "Batch cancelled" }
        if !summary.failures.isEmpty { return "Batch finished with errors" }
        return "Batch complete"
    }

    private var icon: String {
        if summary.cancelled { return "xmark.circle.fill" }
        if !summary.failures.isEmpty { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }
}

#Preview {
    ContentView()
}
