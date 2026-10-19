// PixelmatorBatchApp.swift
//
// App entry point. One main window, a Debug Log window under the Window
// menu, and a custom About window replacing the system panel.

import SwiftUI

@main
struct PixelmatorBatchApp: App {
    init() {
        Log.ui.info("app launched, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
        SelfTest.runIfRequested()
        PixelmatorBridge.sweepStaging()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            AboutCommands()
            CommandGroup(after: .windowArrangement) {
                OpenLogsButton()
            }
        }

        Window("Debug Log", id: "logs") {
            LogsView()
                .frame(minWidth: 760, minHeight: 360)
        }
        .defaultSize(width: 960, height: 480)

        Window("About Pixelmator Batch", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }
}

private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Pixelmator Batch") {
                Log.ui.info("menu: about")
                openWindow(id: "about")
            }
        }
    }
}

private struct OpenLogsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Debug Log") {
            Log.ui.info("menu: debug log")
            openWindow(id: "logs")
        }
        .keyboardShortcut("L", modifiers: [.command, .shift])
    }
}
