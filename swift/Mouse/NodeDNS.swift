import Darwin
import Foundation

/// DNS record lookups for the Node layer (system.md phase G): the `dns.resolve*` family.
///
/// `dns.lookup` has always been real here, because getaddrinfo answers it. The RESOLVERS are a
/// different thing — node reaches a DNS server through c-ares and asks for a specific record
/// type — and they were absent for that reason. A surface sweep put them back on the list as the
/// one genuinely reachable item left.
///
/// The queries go through the system resolver (`res_9_query` in libresolv), which is what
/// `nslookup` and every other tool on the platform uses: nameserver discovery, retries and
/// timeouts come with it, so what is left here is parsing — a DNS answer section, including the
/// pointer compression that makes names impossible to read with a plain byte scan (hence
/// `res_9_dn_expand`, also from libresolv, rather than a hand-rolled walker).
///
/// Blocking calls run on their own queue and answer through a completion, matching how the socket
/// layer treats getaddrinfo: the JS thread never waits.
enum NodeDNS {

    // libresolv's symbols are versioned on Darwin (resolv.h maps `res_query` to `res_9_query`
    // with a macro that Swift's importer does not follow), so they are bound by name.
    @_silgen_name("res_9_query")
    private static func res_query(_ name: UnsafePointer<CChar>, _ cls: Int32, _ type: Int32,
                                 _ answer: UnsafeMutablePointer<UInt8>, _ anslen: Int32) -> Int32

    @_silgen_name("res_9_dn_expand")
    private static func dn_expand(_ msg: UnsafePointer<UInt8>, _ eom: UnsafePointer<UInt8>,
                                  _ src: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<CChar>,
                                  _ dstsiz: Int32) -> Int32

    private static let queue = DispatchQueue(label: "mouse.node.dns", attributes: .concurrent)

    /// `h_errno` is what separates "no such name" from "no record of this type", and node reports
    /// the difference. It is a plain `extern int` on Darwin, which Swift 6 refuses to read as
    /// shared mutable state — so it is reached through `dlsym` (a public lookup of a public
    /// symbol, not private API) and read on the same queue that made the query.
    /// Stored as an address rather than a pointer: a pointer is not Sendable, and this is a
    /// `static let` that every query thread reads.
    private static let hErrnoAddress: Int = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "h_errno") else { return 0 }
        return Int(bitPattern: symbol)
    }()

    private static func hostError() -> Int32 {
        guard hErrnoAddress != 0,
              let pointer = UnsafeMutablePointer<Int32>(bitPattern: hErrnoAddress) else {
            return Int32(HOST_NOT_FOUND)
        }
        return pointer.pointee
    }

    /// A NUL-terminated C buffer as a String, without the deprecated initialiser.
    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
               as: UTF8.self)
    }

    /// node's record types, by the numbers the wire format uses.
    static func typeNumber(_ name: String) -> Int32? {
        switch name.uppercased() {
        case "A": return 1
        case "NS": return 2
        case "CNAME": return 5
        case "SOA": return 6
        case "PTR": return 12
        case "MX": return 15
        case "TXT": return 16
        case "AAAA": return 28
        case "SRV": return 33
        case "NAPTR": return 35
        case "CAA": return 257
        case "TLSA": return 52
        default: return nil
        }
    }

    /// One query, off the JS thread. `nil` records with a code is node's error shape.
    static func resolve(name: String, type: String,
                        completion: @escaping @Sendable ([[String: Any]]?, String?) -> Void) {
        guard let number = typeNumber(type) else {
            completion(nil, "ENOTIMP")
            return
        }
        queue.async {
            var answer = [UInt8](repeating: 0, count: 65_536)
            let length = res_query(name, 1, number, &answer, Int32(answer.count))
            guard length > 0 else {
                // h_errno distinguishes "no such name" from "no record of this type", which node
                // surfaces as ENOTFOUND and ENODATA.
                let code: String
                switch hostError() {
                case Int32(HOST_NOT_FOUND): code = "ENOTFOUND"
                case Int32(NO_DATA): code = "ENODATA"
                case Int32(TRY_AGAIN): code = "ETIMEOUT"
                default: code = "ESERVFAIL"
                }
                completion(nil, code)
                return
            }
            let records = parse(Array(answer[0..<Int(length)]), wanted: number)
            completion(records, records.isEmpty ? "ENODATA" : nil)
        }
    }

    /// A PTR lookup by address, which is what `dns.reverse` is — but getnameinfo already does the
    /// in-addr.arpa dance, so this asks the system rather than building the name.
    static func reverse(address: String, completion: @escaping @Sendable ([String]?, String?) -> Void) {
        queue.async {
            var storage = sockaddr_storage()
            var length: socklen_t = 0
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, address, &v4) == 1 {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_addr = v4
                length = socklen_t(MemoryLayout<sockaddr_in>.size)
                withUnsafeBytes(of: addr) { raw in
                    _ = memcpy(&storage, raw.baseAddress!, Int(length))
                }
            } else if inet_pton(AF_INET6, address, &v6) == 1 {
                var addr = sockaddr_in6()
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_addr = v6
                length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                withUnsafeBytes(of: addr) { raw in
                    _ = memcpy(&storage, raw.baseAddress!, Int(length))
                }
            } else {
                completion(nil, "EINVAL")
                return
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, length, &host, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
                }
            }
            guard status == 0 else {
                completion(nil, status == EAI_NONAME ? "ENOTFOUND" : "ESERVFAIL")
                return
            }
            completion([text(host)], nil)
        }
    }

    /// `dns.lookupService`: an address and port to a hostname and service name.
    static func lookupService(address: String, port: Int,
                              completion: @escaping @Sendable (String?, String?, String?) -> Void) {
        queue.async {
            var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC,
                                 ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                                 ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(address, String(port), &hints, &list) == 0, let first = list else {
                completion(nil, nil, "EINVAL")
                return
            }
            defer { freeaddrinfo(list) }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
            let status = getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen,
                                    &host, socklen_t(NI_MAXHOST),
                                    &service, socklen_t(NI_MAXSERV), 0)
            guard status == 0 else {
                completion(nil, nil, "ENOTFOUND")
                return
            }
            completion(text(host), text(service), nil)
        }
    }

    // MARK: - Parsing the answer section

    private static func name(in message: [UInt8], at offset: Int) -> (String, Int)? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let used: Int32 = message.withUnsafeBufferPointer { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return dn_expand(base, base + raw.count, base + offset, &buffer, 1024)
        }
        guard used > 0 else { return nil }
        return (text(buffer), offset + Int(used))
    }

    private static func short(_ message: [UInt8], _ at: Int) -> Int {
        guard at + 1 < message.count else { return 0 }
        return Int(message[at]) << 8 | Int(message[at + 1])
    }

    private static func long(_ message: [UInt8], _ at: Int) -> UInt32 {
        guard at + 3 < message.count else { return 0 }
        return UInt32(message[at]) << 24 | UInt32(message[at + 1]) << 16
             | UInt32(message[at + 2]) << 8 | UInt32(message[at + 3])
    }

    /// Walk the header, skip the questions, then read the answers of the type asked for. Records
    /// of other types in the same answer (a CNAME chain, typically) are skipped rather than
    /// reported, which is what node does.
    private static func parse(_ message: [UInt8], wanted: Int32) -> [[String: Any]] {
        guard message.count > 12 else { return [] }
        let questions = short(message, 4)
        let answers = short(message, 6)
        var cursor = 12
        for _ in 0..<questions {
            guard let (_, next) = name(in: message, at: cursor) else { return [] }
            cursor = next + 4                     // QTYPE + QCLASS
        }
        var out: [[String: Any]] = []
        for _ in 0..<answers {
            guard let (_, afterName) = name(in: message, at: cursor) else { break }
            var at = afterName
            let type = short(message, at)
            let ttl = long(message, at + 4)
            let dataLength = short(message, at + 8)
            at += 10
            let dataStart = at
            defer { }
            if Int32(type) == wanted, let record = record(message, dataStart, dataLength,
                                                          type: type, ttl: ttl) {
                out.append(record)
            }
            at = dataStart + dataLength
            cursor = at
        }
        return out
    }

    private static func record(_ message: [UInt8], _ start: Int, _ length: Int,
                               type: Int, ttl: UInt32) -> [String: Any]? {
        switch type {
        case 1:   // A
            guard length == 4 else { return nil }
            let text = "\(message[start]).\(message[start + 1]).\(message[start + 2]).\(message[start + 3])"
            return ["value": text, "ttl": Int(ttl)]
        case 28:  // AAAA
            guard length == 16 else { return nil }
            var bytes = in6_addr()
            withUnsafeMutableBytes(of: &bytes) { raw in
                for i in 0..<16 { raw[i] = message[start + i] }
            }
            var rendered = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &bytes, &rendered, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            return ["value": text(rendered), "ttl": Int(ttl)]
        case 2, 5, 12:  // NS, CNAME, PTR — a single name
            guard let (text, _) = name(in: message, at: start) else { return nil }
            return ["value": text, "ttl": Int(ttl)]
        case 15:  // MX
            guard let (exchange, _) = name(in: message, at: start + 2) else { return nil }
            return ["priority": short(message, start), "exchange": exchange, "ttl": Int(ttl)]
        case 16:  // TXT — one or more length-prefixed chunks, which node keeps SEPARATE
            var chunks: [String] = []
            var at = start
            while at < start + length {
                let size = Int(message[at])
                at += 1
                guard at + size <= message.count else { break }
                chunks.append(String(decoding: message[at..<(at + size)], as: UTF8.self))
                at += size
            }
            return ["chunks": chunks, "ttl": Int(ttl)]
        case 6:   // SOA
            guard let (nsname, afterNS) = name(in: message, at: start),
                  let (hostmaster, afterHM) = name(in: message, at: afterNS) else { return nil }
            return ["nsname": nsname, "hostmaster": hostmaster,
                    "serial": Int(long(message, afterHM)),
                    "refresh": Int(long(message, afterHM + 4)),
                    "retry": Int(long(message, afterHM + 8)),
                    "expire": Int(long(message, afterHM + 12)),
                    "minttl": Int(long(message, afterHM + 16)), "ttl": Int(ttl)]
        case 33:  // SRV
            guard let (target, _) = name(in: message, at: start + 6) else { return nil }
            return ["priority": short(message, start), "weight": short(message, start + 2),
                    "port": short(message, start + 4), "name": target, "ttl": Int(ttl)]
        case 35:  // NAPTR
            var at = start + 4
            var strings: [String] = []
            for _ in 0..<3 {
                guard at < message.count else { return nil }
                let size = Int(message[at])
                at += 1
                guard at + size <= message.count else { return nil }
                strings.append(String(decoding: message[at..<(at + size)], as: UTF8.self))
                at += size
            }
            guard let (replacement, _) = name(in: message, at: at), strings.count == 3 else { return nil }
            return ["order": short(message, start), "preference": short(message, start + 2),
                    "flags": strings[0], "service": strings[1], "regexp": strings[2],
                    "replacement": replacement, "ttl": Int(ttl)]
        case 257: // CAA — a flags byte, a length-prefixed tag, then the value to the end
            guard length >= 2 else { return nil }
            let critical = Int(message[start])
            let tagLength = Int(message[start + 1])
            let tagStart = start + 2
            guard tagStart + tagLength <= message.count else { return nil }
            let tag = String(decoding: message[tagStart..<(tagStart + tagLength)], as: UTF8.self)
            let valueStart = tagStart + tagLength
            let valueEnd = start + length
            guard valueEnd <= message.count, valueStart <= valueEnd else { return nil }
            let value = String(decoding: message[valueStart..<valueEnd], as: UTF8.self)
            return ["critical": critical, "tag": tag, "value": value, "ttl": Int(ttl)]
        case 52: // TLSA — usage, selector and matching type, then the association data
            // The refusal here said TLSA needs a TLS stack. That is true of USING the record —
            // a DANE check compares this hash against the certificate a handshake presented —
            // and has nothing to do with resolving it. On the wire it is three bytes and a
            // blob, no harder than CAA, and node returns exactly those four fields.
            guard length >= 4 else { return nil }
            let dataStart = start + 3
            let dataEnd = start + length
            guard dataEnd <= message.count, dataStart <= dataEnd else { return nil }
            return ["certUsage": Int(message[start]),
                    "selector": Int(message[start + 1]),
                    "match": Int(message[start + 2]),
                    "data": [UInt8](message[dataStart..<dataEnd]),
                    "ttl": Int(ttl)]
        default:
            return nil
        }
    }
}
