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
                    await appState.applicationBecameActive()
                    await appState.startServer()
                    await appState.refresh()
                    await appState.importModelsFromDocuments()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        await appState.refresh()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    Task {
                        if phase == .active {
                            await appState.applicationBecameActive()
                            await appState.startServer()
                            await appState.importModelsFromDocuments()
                        } else if phase == .inactive {
                            await appState.applicationBecameInactive()
                        } else if phase == .background {
                            await appState.applicationEnteredBackground()
                        }
                    }
                }
        }
    }
}
