// SelfTest.swift
//
// Headless diagnostic: `open "Pixelmator Batch.app" --args --selftest <input> <output>`
// runs one image through PixelmatorBridge under the app's own process
// identity (responsible process, TCC and sandbox-extension attribution all
// match a real run) and writes a report to ~/Library/Logs/PixelmatorBatch-selftest.log,
// then exits. Used to debug "Pixelmator Pro could not open the file" without
// clicking through the UI.

import Foundation
import AppKit

enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), args.count >= i + 3 else { return }
        let input = URL(fileURLWithPath: args[i + 1])
        let output = URL(fileURLWithPath: args[i + 2])
        let preset = args.count >= i + 4 ? args[i + 3] : ""
        let report = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PixelmatorBatch-selftest.log")
        var lines: [String] = ["selftest \(Date())", "input: \(input.path)", "output: \(output.path)", "preset: \"\(preset)\""]
        let temp = output.deletingLastPathComponent()
            .appendingPathComponent("\(output.deletingPathExtension().lastPathComponent).pixelmatorbatch-tmp.\(output.pathExtension)")
        let format = ExportFormat(normalizedType: ImageScan.normalizedType(for: input))
        let t0 = Date()
        do {
            try PixelmatorBridge.process(input: input, tempOutput: temp, preset: preset, format: format, quality: 90)
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temp, backupItemName: nil, options: [])
            } else {
                try FileManager.default.moveItem(at: temp, to: output)
            }
            lines.append("RESULT: OK in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        } catch {
            try? FileManager.default.removeItem(at: temp)
            lines.append("RESULT: FAIL \(error.localizedDescription)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        exit(0)
    }
}
