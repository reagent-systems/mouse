class Logger {
    var lines: [String] = []
    func log(_ s: String) { lines.append(s) }
}
let logger = Logger()
struct Account {
    var owner: String
    var balance: Int {
        willSet { logger.log("will \(balance)->\(newValue)") }
        didSet { logger.log("did \(oldValue)->\(balance)") }
    }
}
var acct = Account(owner: "z", balance: 10)
acct.balance += 5
acct.balance = 1
print(logger.lines)
class Vehicle {
    var wheels: Int
    var name: String
    init(wheels: Int, name: String) { self.wheels = wheels; self.name = name }
    convenience init() { self.init(wheels: 4, name: "car") }
    var summary: String { "\(name) on \(wheels) wheels" }
}
class Bike: Vehicle {
    init() { super.init(wheels: 2, name: "bike") }
}
print(Vehicle().summary, Bike().summary, Vehicle(wheels: 18, name: "truck").summary)
struct Celsius {
    var degrees: Double
    init(_ d: Double) { degrees = d }
    init?(parsing s: String) {
        guard let d = Double(s) else { return nil }
        degrees = d
    }
}
print(Celsius(20).degrees, Celsius(parsing: "37.5")?.degrees as Any, Celsius(parsing: "hot") as Any)
enum Level: Int, Comparable {
    case low = 1, mid, high
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    init(score: Int) { self = score > 80 ? .high : score > 40 ? .mid : .low }
}
print(Level(score: 90), Level(score: 50), Level(score: 10), [Level.high, .low, .mid].sorted())
class Shape: CustomStringConvertible {
    var description: String { "Shape(\(sides))" }
    let sides: Int
    init(sides: Int) { self.sides = sides }
}
print(Shape(sides: 3), [Shape(sides: 4)])
struct Wrapper { var values: [Int] = [] }
class Holder { var wrapper = Wrapper() }
let h = Holder()
h.wrapper.values.append(1)
h.wrapper.values += [2, 3]
h.wrapper.values[0] = 10
print(h.wrapper.values)
var nested: [String: [String: Int]] = [:]
nested["a", default: [:]]["x"] = 1
nested["a"]?["y"] = 2
print(nested["a"]!.count, nested["a"]!["y"]!)
var arrayOfStructs = [Wrapper(), Wrapper()]
for i in arrayOfStructs.indices { arrayOfStructs[i].values.append(i) }
print(arrayOfStructs.map(\.values))
var counter = 0
func bump() -> Int { counter += 1; return counter }
let results = (0..<3).map { _ in bump() }
print(results, counter)
print("done")
