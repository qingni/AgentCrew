import SwiftUI
import AppKit

@main
struct AgentCrewApp: App {
    @AppStorage(L10n.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @StateObject private var viewModel = AppViewModel()
    @ObservedObject private var profileManager = CLIProfileManager.shared
    @State private var showCLISetup = false

    init() {
        #if SWIFT_PACKAGE
        // When launched via `swift run` the process is a plain executable
        // (not a .app bundle), so macOS treats it as a background process —
        // no Dock icon, no menu bar, no Cmd-Tab entry.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)

            if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
               let icon = NSImage(contentsOf: iconURL) {
                NSApplication.shared.applicationIconImage = icon
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environment(\.locale, Locale(identifier: resolvedLanguage.localeIdentifier))
                .sheet(isPresented: $showCLISetup) {
                    CLIProfileSetupView()
                }
                .onAppear {
                    if profileManager.needsFirstRunSetup {
                        showCLISetup = true
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
    }

    private var resolvedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .system
    }
}
