func makeCounter() -> () -> Int {
    var count = 0
    return {
        count += 1
        return count
    }
}
let counter = makeCounter()
print(counter(), counter(), counter())
let other = makeCounter()
print(other(), counter())
func apply(_ f: (Int) -> Int, to x: Int) -> Int { f(x) }
print(apply({ $0 * 3 }, to: 7))
let square: (Int) -> Int = { x in x * x }
print(square(9))
func compose(_ f: @escaping (Int) -> Int, _ g: @escaping (Int) -> Int) -> (Int) -> Int {
    return { x in g(f(x)) }
}
let addThenSquare = compose({ $0 + 1 }, square)
print(addThenSquare(4))
var handlers: [String: () -> String] = [:]
handlers["hi"] = { "hello" }
handlers["bye"] = { "goodbye" }
print(handlers["hi"]!(), handlers["bye"]?() ?? "")
let sorted = ["banana", "apple", "cherry"].sorted { a, b in a.count < b.count || (a.count == b.count && a < b) }
print(sorted)
func repeatTimes(_ n: Int, _ body: (Int) -> Void) {
    for i in 0..<n { body(i) }
}
repeatTimes(3) { i in print("iteration", i) }
var total = 0
[1, 2, 3].forEach { total += $0 }
print(total)
func fibMemo() -> (Int) -> Int {
    var memo: [Int: Int] = [:]
    func fib(_ n: Int) -> Int {
        if n < 2 { return n }
        if let m = memo[n] { return m }
        let v = fib(n - 1) + fib(n - 2)
        memo[n] = v
        return v
    }
    return fib
}
print(fibMemo()(50))
func outer() -> Int {
    func helper(_ x: Int) -> Int { x * 2 }
    return helper(21)
}
print(outer())
var captured = 1
let addCaptured = { (x: Int) -> Int in x + captured }
captured = 100
print(addCaptured(1))
func swapTwo(_ a: inout Int, _ b: inout Int) { let t = a; a = b; b = t }
var m = 1, n = 2
swapTwo(&m, &n)
print(m, n)
func increment(_ x: inout Int, by step: Int = 1) { x += step }
var k = 10
increment(&k)
increment(&k, by: 5)
print(k)
var arr = [3, 1, 2]
arr.swapAt(0, 2)
print(arr)
func sum(_ values: Int...) -> Int { values.reduce(0, +) }
print(sum(), sum(1), sum(1, 2, 3, 4))
func greet(_ name: String, greeting: String = "Hello", punctuation: String = "!") -> String {
    "\(greeting), \(name)\(punctuation)"
}
print(greet("Ann"), greet("Bo", greeting: "Hi"), greet("Cy", punctuation: "?"))
let words = ["a", "bb", "ccc"]
let lengths = words.map(\.count)
print(lengths)
let result = [1, 2, 3, 4].reduce(into: [Int: Int]()) { acc, x in acc[x % 2, default: 0] += x }
print(result[0]!, result[1]!)
let evens = (1...10).filter { $0.isMultiple(of: 2) }.map(String.init)
print(evens.joined(separator: ","))
