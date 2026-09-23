var name: String? = "Ann"
print(name as Any, name!, name ?? "none")
name = nil
print(name as Any, name ?? "none")
let numbers = ["1", "2", "three", "4"]
let parsed = numbers.map { Int($0) }
print(parsed)
print(parsed.compactMap { $0 })
if let first = parsed.first, let value = first { print("first is", value) }
func lookup(_ key: String) -> Int? { ["a": 1, "b": 2][key] }
print(lookup("a") as Any, lookup("z") as Any)
if let v = lookup("b") { print("found", v) } else { print("missing") }
func describe(_ key: String) -> String {
    guard let v = lookup(key) else { return "\(key): missing" }
    return "\(key): \(v)"
}
print(describe("a"), describe("q"))
struct Person { var name: String; var pet: Pet? }
struct Pet { var name: String; var age: Int? }
let people = [Person(name: "A", pet: Pet(name: "Rex", age: 3)), Person(name: "B", pet: nil), Person(name: "C", pet: Pet(name: "Tom", age: nil))]
for p in people {
    print(p.name, p.pet?.name ?? "no pet", p.pet?.age.map { $0 * 7 } ?? -1)
}
print(people.compactMap { $0.pet?.age })
var optArr: [Int]? = [1, 2]
optArr?.append(3)
print(optArr?.count ?? 0, optArr as Any)
optArr = nil
optArr?.append(4)
print(optArr?.count as Any)
let x: Int? = 4
let y: Int? = nil
print(x == 4, y == nil, x != nil, (x ?? 0) + (y ?? 10))
if let x, x > 3 { print("shorthand", x) }
let nested: Int?? = 5
print(nested as Any)
var countdown: Int? = 3
while let c = countdown, c > 0 {
    print(c)
    countdown = c - 1
}
let dict: [String: [Int]] = ["evens": [2, 4]]
print(dict["evens"]?.first ?? 0, dict["odds"]?.first ?? -1, dict["evens"]?.count as Any)
let str: String? = "hello"
print(str?.uppercased() ?? "", str?.count as Any)
