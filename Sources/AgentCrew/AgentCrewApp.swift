import SwiftUI

@main
struct AgentCrewApp: App {
    @AppStorage(L10n.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @StateObject private var viewModel = AppViewModel()
    @ObservedObject private var profileManager = CLIProfileManager.shared
    @State private var showCLISetup = false

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
