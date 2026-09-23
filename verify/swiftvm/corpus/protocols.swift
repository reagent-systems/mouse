protocol Shape {
    var name: String { get }
    func area() -> Double
}
extension Shape {
    func describe() -> String { "\(name) with area \(area())" }
}
struct Circle: Shape {
    var radius: Double
    var name: String { "circle" }
    func area() -> Double { 3.0 * radius * radius }
}
struct Rect: Shape {
    var w: Double, h: Double
    let name = "rect"
    func area() -> Double { w * h }
}
let shapes: [Shape] = [Circle(radius: 1), Rect(w: 2, h: 3)]
for s in shapes { print(s.describe()) }
print(shapes.map { $0.area() }.reduce(0, +))
protocol Greeter { func greet() -> String }
extension Greeter { func greet() -> String { "Hello from default" } }
struct Quiet: Greeter {}
struct Loud: Greeter { func greet() -> String { "HELLO" } }
print(Quiet().greet(), Loud().greet())
extension Int {
    var squared: Int { self * self }
    func times(_ body: () -> Void) { for _ in 0..<self { body() } }
    mutating func double() { self *= 2 }
}
print(5.squared)
3.times { print("tick") }
var num = 21
num.double()
print(num)
extension String {
    var isPalindrome: Bool { self == String(self.reversed()) }
    func shout() -> String { uppercased() + "!" }
}
print("level".isPalindrome, "swift".isPalindrome, "hey".shout())
extension Array where Element == Int {
    func sum() -> Int { reduce(0, +) }
}
print([1, 2, 3].sum())
struct Version: Comparable, CustomStringConvertible {
    let major: Int, minor: Int
    static func < (a: Version, b: Version) -> Bool { (a.major, a.minor) < (b.major, b.minor) }
    var description: String { "v\(major).\(minor)" }
}
let versions = [Version(major: 1, minor: 2), Version(major: 0, minor: 9), Version(major: 1, minor: 0)]
print(versions.sorted(), versions.max()!, Version(major: 1, minor: 0) < Version(major: 1, minor: 1))
print(Version(major: 2, minor: 0) > Version(major: 1, minor: 9), versions.sorted().map { $0.description })
struct Money: Equatable, Hashable { let cents: Int }
print(Money(cents: 5) == Money(cents: 5), Set([Money(cents: 1), Money(cents: 1)]).count)
protocol Describable { var summary: String { get } }
struct Book: Describable, CustomStringConvertible {
    let title: String
    var summary: String { "Book: \(title)" }
    var description: String { title }
}
let items: [Describable] = [Book(title: "Dune")]
print(items[0].summary, items.first as? Book as Any)
print([Book(title: "A"), Book(title: "B")])
