enum VendingError: Error {
    case invalidSelection
    case insufficientFunds(coinsNeeded: Int)
    case outOfStock
}
struct Item { var price: Int; var count: Int }
class VendingMachine {
    var inventory = ["Candy": Item(price: 12, count: 7), "Chips": Item(price: 10, count: 0)]
    var coinsDeposited = 0
    func vend(itemNamed name: String) throws -> String {
        guard let item = inventory[name] else { throw VendingError.invalidSelection }
        guard item.count > 0 else { throw VendingError.outOfStock }
        guard item.price <= coinsDeposited else {
            throw VendingError.insufficientFunds(coinsNeeded: item.price - coinsDeposited)
        }
        coinsDeposited -= item.price
        inventory[name]!.count -= 1
        return name
    }
}
let machine = VendingMachine()
machine.coinsDeposited = 8
for name in ["Candy", "Chips", "Soda"] {
    do {
        let got = try machine.vend(itemNamed: name)
        print("got", got)
    } catch VendingError.invalidSelection {
        print("invalid selection")
    } catch VendingError.insufficientFunds(let needed) {
        print("need \(needed) more coins")
    } catch {
        print("other error: \(error)")
    }
}
machine.coinsDeposited = 20
print(try! machine.vend(itemNamed: "Candy"), machine.inventory["Candy"]!.count, machine.coinsDeposited)
func parse(_ s: String) throws -> Int {
    guard let v = Int(s) else { throw VendingError.invalidSelection }
    return v
}
print(try? parse("12") as Any, try? parse("x") as Any)
let value = (try? parse("7")) ?? 0
print(value)
struct ValidationError: Error { let field: String }
func validate(age: Int) throws {
    if age < 0 { throw ValidationError(field: "age") }
}
do {
    try validate(age: -1)
} catch let e as ValidationError {
    print("invalid field:", e.field)
}
func rethrowing() throws -> Int {
    defer { print("defer runs") }
    return try parse("5") * 2
}
print(try rethrowing())
func cleanup() {
    defer { print("first defer (runs last)") }
    defer { print("second defer (runs first)") }
    print("body")
}
cleanup()
