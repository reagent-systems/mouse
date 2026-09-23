func isPrime(_ n: Int) -> Bool {
    if n < 2 { return false }
    var i = 2
    while i * i <= n {
        if n % i == 0 { return false }
        i += 1
    }
    return true
}
print((1...50).filter(isPrime))
func sieve(_ limit: Int) -> [Int] {
    var composite = [Bool](repeating: false, count: limit + 1)
    var primes: [Int] = []
    for i in 2...limit {
        if composite[i] { continue }
        primes.append(i)
        var j = i * i
        while j <= limit { composite[j] = true; j += i }
    }
    return primes
}
print(sieve(100).count, sieve(30))
func bubbleSort(_ input: [Int]) -> [Int] {
    var a = input
    for i in 0..<a.count {
        for j in 0..<(a.count - i - 1) where a[j] > a[j + 1] {
            a.swapAt(j, j + 1)
        }
    }
    return a
}
print(bubbleSort([5, 2, 9, 1, 5, 6]))
func quickSort(_ a: [Int]) -> [Int] {
    guard a.count > 1 else { return a }
    let pivot = a[a.count / 2]
    return quickSort(a.filter { $0 < pivot }) + a.filter { $0 == pivot } + quickSort(a.filter { $0 > pivot })
}
print(quickSort([3, 6, 8, 10, 1, 2, 1]))
func binarySearch(_ a: [Int], _ target: Int) -> Int? {
    var lo = 0, hi = a.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        if a[mid] == target { return mid }
        if a[mid] < target { lo = mid + 1 } else { hi = mid - 1 }
    }
    return nil
}
print(binarySearch([1, 3, 5, 7, 9, 11], 7) ?? -1, binarySearch([1, 3], 4) as Any)
func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
print(gcd(48, 18), gcd(17, 5))
func factorial(_ n: Int) -> Int { n <= 1 ? 1 : n * factorial(n - 1) }
print(factorial(20))
var fizz: [String] = []
for i in 1...15 {
    if i % 15 == 0 { fizz.append("FizzBuzz") }
    else if i % 3 == 0 { fizz.append("Fizz") }
    else if i % 5 == 0 { fizz.append("Buzz") }
    else { fizz.append(String(i)) }
}
print(fizz.joined(separator: " "))
func collatz(_ start: Int) -> Int {
    var n = start, steps = 0
    while n != 1 { n = n % 2 == 0 ? n / 2 : 3 * n + 1; steps += 1 }
    return steps
}
print(collatz(27))
var memo = [Int: Int]()
func ways(_ n: Int) -> Int {
    if n <= 1 { return 1 }
    if let v = memo[n] { return v }
    let r = ways(n - 1) + ways(n - 2)
    memo[n] = r
    return r
}
print(ways(40))
func permutations(_ a: [Int]) -> [[Int]] {
    if a.count <= 1 { return [a] }
    var out: [[Int]] = []
    for (i, x) in a.enumerated() {
        var rest = a
        rest.remove(at: i)
        for p in permutations(rest) { out.append([x] + p) }
    }
    return out
}
print(permutations([1, 2, 3]))
let text = "the cat and the hat and the bat"
var freq: [String: Int] = [:]
for w in text.split(separator: " ") { freq[String(w), default: 0] += 1 }
let top = freq.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(3)
print(top.map { "\($0.key)=\($0.value)" })
var board = Array(repeating: Array(repeating: 0, count: 4), count: 4)
for i in 0..<4 { board[i][i] = 1; board[i][3 - i] = 2 }
for row in board { print(row.map(String.init).joined()) }
outer: for i in 1...3 {
    for j in 1...3 {
        if j == 2 { continue outer }
        if i == 3 { break outer }
        print(i, j)
    }
}
var n = 0
repeat { n += 3 } while n < 10
print(n)
