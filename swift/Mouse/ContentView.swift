import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            AsciiLogoBackground()

            ForegroundView()
        }
    }
}

#Preview {
    ContentView()
}
