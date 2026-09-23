import Foundation
let greeting = "Hello"
var count = 3
count += 2
print("\(greeting), world! \(count)")
let pi = 3.14159
let radius = 2
print(pi * Double(radius) * Double(radius))
print(7 / 2, 7 % 2, -7 / 2, -7 % 2, 7.0 / 2)
print(1 + 2 * 3 - 4 / 2)
print(2.5 * 2, 10.0 - 0.1, 1e3, 0.1 + 0.2)
let big = Int.max
print(big, Int.min)
print(true && false, true || false, !true)
let a = 5, b = 10
print(a < b ? "less" : "more")
var x = 10
x -= 3; x *= 2; x /= 7
print(x)
print("multi", "args", 3, separator: "|", terminator: "!\n")
let bits = 0b1010 | 0x0F
print(bits, bits & 0b11, bits ^ 1, bits << 2, bits >> 1, ~0)
print(Double(7) / 2, Int(7.9), Int(-7.9), Int("42") ?? 0, Int("x") ?? -1)
print(abs(-5), abs(-2.5), max(3, 9, 4), min(3.5, 1.5), 2.0.squareRoot())
print(10.isMultiple(of: 5), 7.isMultiple(of: 2), (-3).signum())
print((3.7).rounded(), (3.2).rounded(.up), (-3.7).rounded(.down), 3.5.rounded(.toNearestOrEven))
print(String(255, radix: 16), String(5, radix: 2), Int("ff", radix: 16)!)
print(Double.pi, Double.infinity, -Double.infinity)
print(10.0.truncatingRemainder(dividingBy: 3), pow(2.0, 10.0), floor(2.7), ceil(2.1))
let tuple = (1, "two", 3.0)
print(tuple, tuple.0, tuple.1)
let named = (x: 1, y: 2)
print(named.x + named.y, named)
let (q, r) = (17 / 5, 17 % 5)
print(q, r)
var (m, n) = (1, 2)
(m, n) = (n, m)
print(m, n)
