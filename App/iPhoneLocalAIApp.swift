import SwiftUI

@main
struct IPhoneLocalAIApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .task {
                    await appState.startServer()
                    await appState.refresh()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        await appState.refresh()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    Task {
                        if phase == .active {
                            await appState.startServer()
                        } else if phase == .background {
                            await appState.stopServer()
                        }
                    }
                }
        }
    }
}
