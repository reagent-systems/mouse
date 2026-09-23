var numbers = [5, 3, 8, 1, 9, 2]
print(numbers.count, numbers.first!, numbers.last!, numbers[2])
numbers.append(7)
numbers.insert(0, at: 0)
print(numbers)
numbers.sort()
print(numbers, numbers.sorted(by: >))
print(numbers.min()!, numbers.max()!, numbers.contains(8), numbers.firstIndex(of: 8)!)
print(numbers.map { $0 * $0 })
print(numbers.filter { $0 % 2 == 0 })
print(numbers.reduce(0, +), numbers.reduce(1) { $0 * max($1, 1) })
print(numbers.reversed() as [Int])
let removed = numbers.remove(at: 0)
print(removed, numbers.removeLast(), numbers.removeFirst(), numbers)
print(numbers.prefix(2), numbers.suffix(2), Array(numbers.dropFirst(3)))
print(numbers.enumerated().map { "\($0.offset):\($0.element)" })
for (i, v) in ["a", "b"].enumerated() { print(i, v) }
print(numbers.allSatisfy { $0 > 0 }, numbers.contains { $0 > 8 })
print([[1, 2], [3], []].flatMap { $0 }, ["1", "x", "3"].compactMap { Int($0) })
print(Array(1...5), Array(0..<3), Array(stride(from: 0, to: 10, by: 3)))
print(zip([1, 2, 3], ["a", "b", "c"]).map { "\($0)\($1)" })
var matrix = [[0, 0], [0, 0]]
matrix[1][0] = 5
matrix[0].append(9)
print(matrix)
var grid = Array(repeating: Array(repeating: ".", count: 3), count: 2)
grid[0][1] = "#"
print(grid.map { $0.joined() }.joined(separator: "/"))
var scores = ["alice": 90, "bob": 72]
scores["carol"] = 85
scores["bob"] = nil
print(scores.count, scores["alice"]!, scores["bob"] as Any, scores["zed", default: 0])
for key in scores.keys.sorted() { print(key, scores[key]!) }
let byLength = Dictionary(grouping: ["one", "two", "three", "four"]) { $0.count }
for k in byLength.keys.sorted() { print(k, byLength[k]!) }
var counts: [Character: Int] = [:]
for ch in "mississippi" { counts[ch, default: 0] += 1 }
print(counts.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" }.joined())
let mapped = scores.mapValues { $0 + 1 }
print(mapped["alice"]!)
var set: Set<Int> = [1, 2, 3]
set.insert(3)
set.insert(4)
print(set.count, set.contains(2), set.sorted())
let other: Set = [3, 4, 5]
print(set.intersection(other).sorted(), set.union(other).sorted(), set.subtracting(other).sorted())
var stack: [String] = []
stack.append("a"); stack.append("b")
print(stack.popLast() ?? "none", stack)
print([3, 1, 2].sorted(), ["b", "a"].sorted(), [1, 2] + [3])
var arr2 = [1, 2, 3, 4, 5, 6]
arr2.removeAll { $0 % 2 == 0 }
print(arr2, arr2.isEmpty, [Int]().isEmpty)
print(arr2.indices.map { $0 * 10 })
let words = ["apple", "Banana", "cherry"]
print(words.map { $0.count }, words.sorted { $0.lowercased() < $1.lowercased() })
print(words.first { $0.hasPrefix("c") } ?? "none", words.last!)
var empty: [String: [Int]] = [:]
empty["x", default: []].append(1)
empty["x", default: []].append(2)
print(empty)
let nested = ["a": ["b": 1]]
print(nested["a"]?["b"] ?? 0)
print(Array(numbers.lazy.map { $0 + 1 }))
print([1, 2, 3].elementsEqual([1, 2, 3]), [1, 2, 2, 3].firstIndex(where: { $0 > 1 })!)
