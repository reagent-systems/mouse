import Foundation
func swapValues<T>(_ a: inout T, _ b: inout T) { let t = a; a = b; b = t }
var s1 = "left", s2 = "right"
swapValues(&s1, &s2)
print(s1, s2)
func largest<T: Comparable>(_ items: [T]) -> T? {
    guard var best = items.first else { return nil }
    for item in items where item > best { best = item }
    return best
}
print(largest([3, 9, 2])!, largest(["pear", "apple"])!, largest([Int]()) as Any)
struct Queue<T> {
    private var items: [T] = []
    mutating func enqueue(_ x: T) { items.append(x) }
    mutating func dequeue() -> T? { items.isEmpty ? nil : items.removeFirst() }
    var count: Int { items.count }
}
var q = Queue<String>()
q.enqueue("a"); q.enqueue("b")
print(q.dequeue()!, q.count, q.dequeue()!, q.dequeue() as Any)
struct Pair<A, B> { let first: A; let second: B }
let pair = Pair(first: 1, second: "one")
print(pair.first, pair.second)
func countWhere<S: Sequence>(_ s: S, _ pred: (S.Element) -> Bool) -> Int {
    var n = 0
    for x in s where pred(x) { n += 1 }
    return n
}
print(countWhere([1, 2, 3, 4], { $0 > 2 }), countWhere("banana") { $0 == "a" })
protocol Container {
    associatedtype Item
    var items: [Item] { get }
}
struct Box: Container { var items: [Int] }
print(Box(items: [1, 2]).items)
typealias Score = (name: String, points: Int)
let scores: [Score] = [("a", 3), ("b", 7)]
print(scores.max { $0.points < $1.points }!.name)
func minMax(_ a: [Int]) -> (min: Int, max: Int) { (a.min()!, a.max()!) }
let mm = minMax([4, 1, 8])
print(mm.min, mm.max, mm)
struct Outer {
    struct Inner { var v = 7 }
    enum Kind { case a, b }
    var inner = Inner()
    var kind = Kind.b
}
let o = Outer()
print(o.inner.v, o.kind, Outer.Inner(v: 2).v, o)
class Base {
    var id: Int
    required init(id: Int) { self.id = id }
    class func make() -> Self { Self(id: 99) }
    func describe() -> String { "Base \(id)" }
}
class Derived: Base {
    var extra = "x"
    override func describe() -> String { "Derived \(id) \(extra)" }
}
print(Derived(id: 1).describe(), Base(id: 2).describe())
enum Math {
    static let e = 2.718
    static func cube(_ x: Int) -> Int { x * x * x }
}
print(Math.e, Math.cube(3))
struct Config {
    static var shared = Config()
    var verbose = false
}
Config.shared.verbose = true
print(Config.shared.verbose)
let formatted = String(format: "%.2f|%5d|%03d|%x", 3.14159, 42, 7, 255)
print(formatted)
print(String(format: "%d%%", 50))
let items = [("apple", 1.5), ("kiwi", 0.25)]
for (fruit, price) in items { print("\(fruit): $\(String(format: "%.2f", price))") }
var total = 0
for i in stride(from: 10, through: 0, by: -5) { total += i }
print(total)
print((1...4).map { $0 * $0 }.reversed() as [Int])
let dictOfArrays = ["x": [3, 1], "y": [2]]
print(dictOfArrays.keys.sorted(), dictOfArrays.values.map { $0.count }.sorted())
