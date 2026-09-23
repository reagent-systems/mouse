struct Point: Equatable {
    var x: Int
    var y: Int
    static let origin = Point(x: 0, y: 0)
    func moved(dx: Int, dy: Int) -> Point { Point(x: x + dx, y: y + dy) }
    mutating func move(dx: Int, dy: Int) { x += dx; y += dy }
    var magnitudeSquared: Int { x * x + y * y }
    static func + (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
}
var p = Point(x: 1, y: 2)
let q = p
p.move(dx: 10, dy: 10)
print(p, q, p == q, q == Point(x: 1, y: 2))
print(p.moved(dx: -1, dy: -1), p.magnitudeSquared, Point.origin)
print(p + q)
struct Rect {
    var origin = Point(x: 0, y: 0)
    var width: Int
    var height: Int
    var area: Int { width * height }
    var center: Point {
        get { Point(x: origin.x + width / 2, y: origin.y + height / 2) }
        set {
            origin.x = newValue.x - width / 2
            origin.y = newValue.y - height / 2
        }
    }
}
var r = Rect(width: 10, height: 4)
print(r.area, r.center)
r.center = Point(x: 50, y: 50)
print(r.origin, r)
r.origin.x += 1
print(r.origin.x)
struct Stack<Element> {
    private var items: [Element] = []
    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    mutating func push(_ item: Element) { items.append(item) }
    mutating func pop() -> Element? { items.popLast() }
    func peek() -> Element? { items.last }
}
var s = Stack<Int>()
s.push(1); s.push(2); s.push(3)
print(s.pop()!, s.count, s.peek()!, s.isEmpty)
struct Temperature {
    var celsius: Double
    var fahrenheit: Double { celsius * 9 / 5 + 32 }
    init(celsius: Double) { self.celsius = celsius }
    init(fahrenheit: Double) { self.celsius = (fahrenheit - 32) * 5 / 9 }
}
print(Temperature(celsius: 100).fahrenheit, Temperature(fahrenheit: 212).celsius)
struct Counter {
    var value = 0 {
        didSet { print("changed from \(oldValue) to \(value)") }
    }
}
var c = Counter()
c.value = 5
c.value += 1
struct Team {
    var members: [String] = []
    mutating func add(_ name: String) { members.append(name) }
}
var teams = [Team(), Team()]
teams[1].add("ann")
teams[1].members.append("ben")
print(teams.map { $0.members })
struct Matrix {
    var rows: Int, cols: Int
    var data: [Double]
    init(rows: Int, cols: Int) {
        self.rows = rows; self.cols = cols
        data = Array(repeating: 0.0, count: rows * cols)
    }
    subscript(r: Int, c: Int) -> Double {
        get { data[r * cols + c] }
        set { data[r * cols + c] = newValue }
    }
}
var mat = Matrix(rows: 2, cols: 2)
mat[0, 1] = 3.5
mat[1, 1] += 2
print(mat.data, mat[0, 1])
