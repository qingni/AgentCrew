import SwiftUI

@main
struct AgentCrewApp: App {
    @StateObject private var viewModel = AppViewModel()
    @ObservedObject private var profileManager = CLIProfileManager.shared
    @State private var showCLISetup = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
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
}
