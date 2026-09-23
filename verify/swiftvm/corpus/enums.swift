enum Direction: CaseIterable {
    case north, south, east, west
    var opposite: Direction {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }
}
print(Direction.north, Direction.north.opposite, Direction.allCases.count)
let d: Direction = .east
print(d == .east, d != .west)
enum Planet: Int {
    case mercury = 1, venus, earth, mars
}
print(Planet.earth.rawValue, Planet(rawValue: 4) ?? .mercury, Planet(rawValue: 9) as Any)
enum Suit: String { case hearts = "♥", spades = "♠"; case clubs }
print(Suit.hearts.rawValue, Suit.clubs.rawValue, Suit(rawValue: "♠")!)
enum Result2 {
    case success(value: Int)
    case failure(message: String)
}
let results: [Result2] = [.success(value: 42), .failure(message: "oops")]
for r in results {
    switch r {
    case .success(let v) where v > 40: print("big success", v)
    case .success(let v): print("success", v)
    case .failure(let m): print("failed:", m)
    }
}
enum Expr {
    case num(Int)
    indirect case add(Expr, Expr)
    indirect case mul(Expr, Expr)
    func eval() -> Int {
        switch self {
        case .num(let n): return n
        case let .add(a, b): return a.eval() + b.eval()
        case let .mul(a, b): return a.eval() * b.eval()
        }
    }
}
print(Expr.add(.num(2), .mul(.num(3), .num(4))).eval())
enum Light { case red, yellow, green
    mutating func next() {
        switch self {
        case .red: self = .green
        case .green: self = .yellow
        case .yellow: self = .red
        }
    }
}
var light = Light.red
light.next(); print(light)
light.next(); print(light)
if case .yellow = light { print("caution") }
let value = 15
switch value {
case 0: print("zero")
case 1...9: print("single digit")
case 10..<100: print("double digit")
default: print("big")
}
let point = (2, 0)
switch point {
case (0, 0): print("origin")
case (_, 0): print("on x axis")
case (0, _): print("on y axis")
default: print("elsewhere")
}
let pair = (3, 3)
switch pair {
case let (a, b) where a == b: print("diagonal \(a)")
default: print("off")
}
let ch: Character = "e"
switch ch {
case "a", "e", "i", "o", "u": print("vowel")
default: print("consonant")
}
enum Coin: Int, CaseIterable { case penny = 1, nickel = 5, dime = 10 }
print(Coin.allCases.map { $0.rawValue }.reduce(0, +))
print(Coin.allCases)
let maybe: Int? = 5
switch maybe {
case .some(let v): print("has", v)
case .none: print("none")
}
