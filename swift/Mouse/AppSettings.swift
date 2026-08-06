import SwiftUI

/// App-wide, user-set switches — one instance, UserDefaults-backed, the same one-object
/// pattern as `GitHubAuth.shared`. Their controls live on the GitHub container's signed-in
/// face, which is the one container that is about the APP rather than the workspace.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Dark canvas: the backdrop turns dark gray, the ascii logo renders in near-dark tints
    /// of the same two hues, and canvas-facing chrome (ring dots, lesson labels) flips to
    /// white. The containers themselves are already black in both.
    var darkCanvas: Bool {
        didSet { UserDefaults.standard.set(darkCanvas, forKey: Self.darkCanvasKey) }
    }

    /// Bumped by "rerun onboarding" on the GitHub container; `ForegroundView` watches it and
    /// inserts a fresh onboarding ring beside the current one. A counter rather than a flag,
    /// so asking again while a lesson ring is already open still asks.
    private(set) var onboardingRuns = 0
    func requestOnboarding() { onboardingRuns += 1 }

    /// The canvas and the chrome that sits directly on it, in one place — no view invents
    /// its own reading of the theme.
    var canvasColor: Color { darkCanvas ? Color(white: 0.16) : .white }
    var canvasChrome: Color { darkCanvas ? .white : .black }

    private static let darkCanvasKey = "darkCanvas"

    private init() {
        darkCanvas = UserDefaults.standard.bool(forKey: Self.darkCanvasKey)
    }
}
