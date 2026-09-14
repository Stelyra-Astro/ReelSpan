import SwiftUI

@main
struct ReelAtlasApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: model.effectiveInterfaceLanguage))
        }
    }
}
