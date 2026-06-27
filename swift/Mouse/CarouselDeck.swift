import SwiftUI

/// One horizontal carousel lane: a set of panels plus its current page and current height.
struct Lane: Identifiable {
    let id = UUID()
    var panels: [PanelStyle]
    var selection: Int = 0
    var height: CGFloat = 0
}

/// The vertical stack of carousel lanes.
@Observable
final class CarouselDeck {
    var lanes: [Lane]

    init(lanes: [Lane]) {
        self.lanes = lanes
    }

    static func demo() -> CarouselDeck {
        CarouselDeck(lanes: [
            Lane(panels: PanelStyle.palette(offset: 0)),
            Lane(panels: PanelStyle.palette(offset: 3)),
            Lane(panels: PanelStyle.palette(offset: 6)),
        ])
    }
}

struct PanelStyle {
    let title: String
    let color: Color

    static func palette(offset: Int) -> [PanelStyle] {
        let colors: [Color] = [.black, .blue, .purple, .indigo, .teal, .brown, .pink, .orange, .green]
        return (0..<3).map { i in
            let index = (offset + i) % colors.count
            return PanelStyle(title: "\(offset + i + 1)", color: colors[index])
        }
    }
}
