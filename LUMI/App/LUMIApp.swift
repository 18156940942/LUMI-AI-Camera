import SwiftUI

@main
struct LUMIApp: App {

    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) private var orientationDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
                .environmentObject(appState.favorites)
                .environmentObject(appState.poseLibrary)
                .environmentObject(appState.videoInput)
                .environmentObject(appState.photoLibrary)
                .preferredColorScheme(.dark)
                .tint(LumiTheme.accent)
        }
    }
}
