import Foundation
let s = "Hello, Swift"
print(s.count, s.isEmpty, s.uppercased(), s.lowercased())
print(s.hasPrefix("Hell"), s.hasSuffix("ft"), s.contains("lo, S"))
print(s.first!, s.last!, s.first as Any)
print(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
print(s.replacingOccurrences(of: "Swift", with: "World"))
print(String(s.reversed()))
print(Array("abc"), "abc".map { $0.uppercased() })
for ch in "hey" { print(ch, terminator: " ") }
print()
print(s.components(separatedBy: ", "))
var t = "abc"
t += "def"
t.append("g")
print(t, t.count)
print(String(repeating: "=", count: 10))
let multi = """
    Line one
      indented
    Line "three"
    """
print(multi)
print("tab\there", "quote\"s", "back\\slash")
print("a" < "b", "apple" < "banana", "Z" < "a")
let word = "racecar"
print(word == String(word.reversed()) ? "palindrome" : "not")
let chars = "hello world".filter { $0 != "o" }
print(chars)
print("hello".prefix(3), "hello".suffix(2), "hello".dropFirst(), "hello".dropLast(2))
let csv = "name,age,city"
let parts = csv.split(separator: ",")
print(parts.count, parts[1])
print("Swift".lowercased().sorted())
let sentence = "the quick brown fox"
let capitalized = sentence.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
print(capitalized)
print("a1b2c3".filter { $0.isNumber }, "a1b2c3".filter { $0.isLetter })
let n = 42
print("The answer is \(n), doubled \(n * 2), \(n > 40 ? "big" : "small")")
print("nested \("inner \(n + 1)")")
print(String(describing: 3.0), String(7))
var vowels = 0
for c in "programming language" where "aeiou".contains(c) { vowels += 1 }
print("vowels:", vowels)
print(Character("x"), "x".unicodeScalars.first!.value)
print("abc".contains("b"), "Hello".lowercased() == "hello")
print("  padded  ".trimmingCharacters(in: .whitespaces) + "|")
