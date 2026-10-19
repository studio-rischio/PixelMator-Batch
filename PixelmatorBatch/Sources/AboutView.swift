// AboutView.swift
//
// Custom About window content. Replaces the system about panel via
// `CommandGroup(replacing: .appInfo)` in PixelmatorBatchApp so we can show
// the app icon, version/build numbers, a short description, and the
// publisher block. Reads app identity from `Bundle.main.infoDictionary` so a
// build-settings version or copyright bump propagates automatically.

import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            appIcon
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)

            Text(appName)
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version \(shortVersion) (\(buildVersion))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text("A Pixelmator Pro automation tool. Applies a color adjustments preset to every image in a folder by driving Pixelmator Pro over AppleScript, then exports the results in their original formats.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            Rectangle().fill(Color(NSColor.separatorColor)).frame(width: 220, height: 0.5)

            // Requirement line. Pixelmator Pro is not bundled — it has to be
            // installed separately, and the app is useless without it.
            VStack(spacing: 3) {
                creditLine(
                    "Pixelmator Pro",
                    url: "https://www.pixelmator.com/pro/",
                    note: pixelmatorStatus
                )
            }

            // Publisher block. The copyright string comes from
            // NSHumanReadableCopyright so the build setting stays the single
            // source of truth; the studio link rides behind the same guard so
            // a fork that clears the setting gets neither.
            if !copyright.isEmpty {
                Rectangle().fill(Color(NSColor.separatorColor)).frame(width: 220, height: 0.5)

                VStack(spacing: 4) {
                    Text(copyright)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let studio = URL(string: "https://rischio.studio") {
                        Link("rischio.studio", destination: studio)
                            .font(.caption2)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { Log.ui.info("about window shown") }
    }

    @ViewBuilder
    private func creditLine(_ name: String, url: String, note: String) -> some View {
        HStack(spacing: 6) {
            if let u = URL(string: url) {
                Link(name, destination: u)
                    .font(.system(size: 11, weight: .medium))
            } else {
                Text(name).font(.system(size: 11, weight: .medium))
            }
            Text("·")
                .foregroundStyle(.tertiary)
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var pixelmatorStatus: String {
        guard let url = PixelmatorBridge.appURL else { return "not installed" }
        let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { "version \($0) installed" } ?? "installed"
    }

    private var appIcon: Image {
        if let ns = NSApplication.shared.applicationIconImage {
            return Image(nsImage: ns)
        }
        return Image(systemName: "photo.stack")
    }

    private var appName: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "Pixelmator Batch"
    }

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }
}

#Preview {
    AboutView()
}
