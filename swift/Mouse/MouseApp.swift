import SwiftUI

@main
struct MouseApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear(perform: applyWindowMinimum)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { applyWindowMinimum() }
        }
    }

    /// iPad multitasking (Stage Manager) may resize the window; never let it shrink below an
    /// iPhone-sized canvas — the smallest layout the lane stack is designed for. iPhone scenes
    /// have no size restrictions (the property is nil there), so this is a no-op on phones.
    private func applyWindowMinimum() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 390, height: 700)
        }
    }
}
