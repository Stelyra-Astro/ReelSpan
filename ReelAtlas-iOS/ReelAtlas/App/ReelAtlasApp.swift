import SwiftUI

@main
struct ReelAtlasApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: model.effectiveInterfaceLanguage))
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.resumeContentSync() } }
                }
        }
    }
}
