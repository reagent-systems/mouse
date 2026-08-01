import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// HPACK, the header compression HTTP/2 speaks — and the first half of the last big gap in the
// node surface. It is verified against **the RFC's own examples**, extracted from RFC 7541
// rather than retyped: three requests over one connection and three responses over another, in
// both spellings (raw literals and Huffman), which puts the DYNAMIC TABLE under test as much as
// any single encoding — the second message refers back to what the first added.
//
// The two tables are transcribed from the RFC's appendices the same way. A transcription can be
// checked against its source; a retyping cannot.

let base = FileManager.default.temporaryDirectory.appendingPathComponent("hpack-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

let script = #"""
const VECTORS = [{"name": "C.3.1.", "huffman": false, "headers": [[":method", "GET"], [":scheme", "http"], [":path", "/"], [":authority", "www.example.com"]], "hex": "828684410f7777772e6578616d706c652e636f6d"}, {"name": "C.3.2.", "huffman": false, "headers": [[":method", "GET"], [":scheme", "http"], [":path", "/"], [":authority", "www.example.com"], ["cache-control", "no-cache"]], "hex": "828684be58086e6f2d6361636865"}, {"name": "C.3.3.", "huffman": false, "headers": [[":method", "GET"], [":scheme", "https"], [":path", "/index.html"], [":authority", "www.example.com"], ["custom-key", "custom-value"]], "hex": "828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565"}, {"name": "C.4.1.", "huffman": true, "headers": [[":method", "GET"], [":scheme", "http"], [":path", "/"], [":authority", "www.example.com"]], "hex": "828684418cf1e3c2e5f23a6ba0ab90f4ff"}, {"name": "C.4.2.", "huffman": true, "headers": [[":method", "GET"], [":scheme", "http"], [":path", "/"], [":authority", "www.example.com"], ["cache-control", "no-cache"]], "hex": "828684be5886a8eb10649cbf"}, {"name": "C.4.3.", "huffman": true, "headers": [[":method", "GET"], [":scheme", "https"], [":path", "/index.html"], [":authority", "www.example.com"], ["custom-key", "custom-value"]], "hex": "828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf"}, {"name": "C.5.1.", "huffman": false, "headers": [[":status", "302"], ["cache-control", "private"], ["date", "Mon, 21 Oct 2013 20:13:21 GMT"], ["location", "https://www.example.com"]], "hex": "4803333032580770726976617465611d4d6f6e2c203231204f637420323031332032303a31333a323120474d546e1768747470733a2f2f7777772e6578616d706c652e636f6d"}, {"name": "C.5.2.", "huffman": false, "headers": [[":status", "307"], ["cache-control", "private"], ["date", "Mon, 21 Oct 2013 20:13:21 GMT"], ["location", "https://www.example.com"]], "hex": "4803333037c1c0bf"}, {"name": "C.5.3.", "huffman": false, "headers": [[":status", "200"], ["cache-control", "private"], ["date", "Mon, 21 Oct 2013 20:13:22 GMT"], ["location", "https://www.example.com"], ["content-encoding", "gzip"], ["set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"]], "hex": "88c1611d4d6f6e2c203231204f637420323031332032303a31333a323220474d54c05a04677a69707738666f6f3d4153444a4b48514b425a584f5157454f50495541585157454f49553b206d61782d6167653d333630303b2076657273696f6e3d31"}, {"name": "C.6.1.", "huffman": true, "headers": [[":status", "302"], ["cache-control", "private"], ["date", "Mon, 21 Oct 2013 20:13:21 GMT"], ["location", "https://www.example.com"]], "hex": "488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3"}, {"name": "C.6.2.", "huffman": true, "headers": [[":status", "307"], ["cache-control", "private"], ["date", "Mon, 21 Oct 2013 20:13:21 GMT"], ["location", "https://www.example.com"]], "hex": "4883640effc1c0bf"}, {"name": "C.6.3.", "huffman": true, "headers": [[":status", "200"], ["cache-control", "private"], ["date", "Mon, 21 Oct 2013 20:13:22 GMT"], ["location", "https://www.example.com"], ["content-encoding", "gzip"], ["set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"]], "hex": "88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007"}];
const hpack = globalThis.__hpack;
const results = [];

// The RFC's own series: each is THREE requests (or responses) over ONE connection, so the
// dynamic table's evolution is under test as much as any single encoding — the second message
// refers back to what the first added, and the third to both.
for (const huffman of [false, true]) {
  for (const kind of ['C.3', 'C.4', 'C.5', 'C.6']) {
    const series = VECTORS.filter((v) => v.name.startsWith(kind) && v.huffman === huffman);
    if (!series.length) continue;
    const encoder = new hpack.Encoder(kind === 'C.5' || kind === 'C.6' ? 256 : 4096);
    const decoder = new hpack.Decoder(kind === 'C.5' || kind === 'C.6' ? 256 : 4096);
    for (const vector of series) {
      const encoded = encoder.encode(vector.headers, { huffman: huffman }).toString('hex');
      results.push(vector.name + ' encode -> ' + (encoded === vector.hex ? 'matches the RFC'
                   : 'DIFFERS\n    ours: ' + encoded + '\n    rfc:  ' + vector.hex));
      const decoded = decoder.decode(Buffer.from(vector.hex, 'hex'));
      const same = JSON.stringify(decoded) === JSON.stringify(vector.headers);
      results.push(vector.name + ' decode -> ' + (same ? 'matches the RFC'
                   : 'DIFFERS\n    ours: ' + JSON.stringify(decoded) + '\n    rfc:  ' + JSON.stringify(vector.headers)));
    }
  }
}

// Huffman on its own, including the padding rule and a string that gets LONGER encoded.
results.push('huffman round trip -> ' + (hpack.huffmanDecode(hpack.huffmanEncode('www.example.com')) === 'www.example.com'));
results.push('huffman of the RFC example -> ' + (hpack.huffmanEncode('www.example.com').toString('hex') === 'f1e3c2e5f23a6ba0ab90f4ff'));
results.push('huffman decodes what it wrote for every byte -> ' + (function() {
  for (let start = 0; start < 256; start += 16) {
    const text = Array.from({ length: 16 }, (_, i) => String.fromCharCode(start + i)).join('');
    if (hpack.huffmanDecode(hpack.huffmanEncode(text)) !== text) return 'FAILED at ' + start;
  }
  return true;
})());
// A literal that Huffman makes longer must be sent RAW — the length prefix's top bit says which.
results.push('incompressible stays raw -> ' + (function() {
  // A value whose Huffman form is LONGER must travel raw, and the way to see that is to find
  // its bytes in the output — reading a length prefix by counting back from the end is a guess.
  const encoder = new hpack.Encoder();
  const value = 'ÿþý';
  const bytes = encoder.encode([['x-b', value]], { huffman: true });
  return bytes.includes(Buffer.from(value, 'utf8'));
})());
// The dynamic table evicts by SIZE, and an entry costs its bytes plus 32.
results.push('eviction -> ' + (function() {
  const decoder = new hpack.Decoder(64);
  const encoder = new hpack.Encoder(64);
  encoder.encode([['aaaa', 'bbbb']]);
  encoder.encode([['cccc', 'dddd']]);
  return encoder.table.entries.length === 1 && encoder.table.entries[0][0] === 'cccc';
})());

console.log(results.join('\n'));
"""#

let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: script, path: "/probe.cjs", argv: ["node", "/probe.cjs"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("stderr: \(ours.err.prefix(600))") }
print(ours.out)

let lines = ours.out.components(separatedBy: "\n").filter { !$0.isEmpty }
let failures = lines.filter { $0.contains("DIFFERS") || $0.contains("-> false") || $0.contains("FAILED") }
if failures.isEmpty, lines.count >= 20 {
    print("HPACK MATCH — \(lines.count) checks against RFC 7541's own vectors: every example "
          + "encodes to the bytes the RFC prints and decodes back to the headers it names, "
          + "across two connections' worth of dynamic-table history")
} else {
    print("MISMATCH: \(failures.count) of \(lines.count)")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
