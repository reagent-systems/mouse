import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            AsciiLogoBackground()

            GlassScreenContainer {
                Color.clear
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
