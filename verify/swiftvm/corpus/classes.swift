class Animal {
    let name: String
    var sound: String { "..." }
    init(name: String) { self.name = name }
    func speak() -> String { "\(name) says \(sound)" }
}
class Dog: Animal {
    override var sound: String { "Woof" }
    var tricks: [String] = []
    func learn(_ trick: String) { tricks.append(trick) }
}
class Cat: Animal {
    let indoor: Bool
    init(name: String, indoor: Bool) {
        self.indoor = indoor
        super.init(name: name)
    }
    override var sound: String { "Meow" }
    override func speak() -> String { super.speak() + (indoor ? " (indoors)" : "") }
}
let dog = Dog(name: "Rex")
dog.learn("sit")
dog.learn("roll")
let animals: [Animal] = [dog, Cat(name: "Tom", indoor: true), Animal(name: "Generic")]
for a in animals { print(a.speak()) }
print(dog.tricks)
for a in animals {
    if let d = a as? Dog { print("dog with \(d.tricks.count) tricks") }
    else if a is Cat { print("a cat") }
    else { print("something else") }
}
class Node {
    var value: Int
    var next: Node?
    init(_ value: Int, next: Node? = nil) { self.value = value; self.next = next }
}
let list = Node(1, next: Node(2, next: Node(3)))
var cursor: Node? = list
var total = 0
while let node = cursor { total += node.value; cursor = node.next }
print(total, list.next?.next?.value ?? 0, list.next?.next?.next?.value as Any)
class BankAccount {
    private(set) var balance: Double = 0
    static var accountsOpened = 0
    init() { BankAccount.accountsOpened += 1 }
    func deposit(_ amount: Double) { balance += amount }
    func withdraw(_ amount: Double) -> Bool {
        guard amount <= balance else { return false }
        balance -= amount
        return true
    }
}
let acct = BankAccount()
_ = BankAccount()
acct.deposit(100)
print(acct.withdraw(30), acct.withdraw(100), acct.balance, BankAccount.accountsOpened)
let alias = acct
alias.deposit(5)
print(acct.balance, alias === acct)
class Shape {
    func area() -> Double { 0 }
    func describe() -> String { "Shape with area \(area())" }
}
class Square: Shape {
    let side: Double
    init(side: Double) { self.side = side }
    override func area() -> Double { side * side }
}
print(Square(side: 3).describe())
print(dog)
