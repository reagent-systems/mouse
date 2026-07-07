import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            AsciiLogoBackground()

            ForegroundView()
        }
        // The keyboard never moves the app: containers that take text input handle the keyboard
        // themselves (the in-place editor scrolls its caret into view). Must sit at the root —
        // any ancestor that respects the keyboard safe area would shift everything up.
        .ignoresSafeArea(.keyboard)
    }
}

#Preview {
    ContentView()
}
