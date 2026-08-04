import Foundation

// Phase A verification: the same script runs through msh (via its own `sh` script path,
// which captures raw stdout) and through /bin/sh, then stdout + exit status are compared.
// Each side gets its own scratch directory.

let corpus: [(name: String, script: String)] = [
    ("echo", "echo hi\necho a b   c"),
    ("quoting", "echo \"a  b\" 'c  d' e\\ f\necho \"mixed 'inner'\" 'and \"outer\"'"),
    ("vars", "X=5\necho $X\nY=\"a b\"\necho \"$Y\"\necho ${Y}z"),
    ("field-splitting", "X=\"a  b c\"\nset -- $X\necho $#\necho \"$Y\" | cat"),
    ("if-elif-else", """
    if [ 3 -gt 2 ]; then echo bigger; fi
    if [ a = b ]; then echo no; elif [ -n hi ]; then echo elif; else echo else; fi
    if [ a = b ]
    then
      echo no
    else
      echo multiline
    fi
    """),
    ("test-ops", """
    [ -z "" ] && echo empty
    [ -n "x" ] && echo nonempty
    [ 5 -le 5 ] && echo le
    [ abc != abd ] && echo ne
    test 1 -lt 2 && echo lt
    [ a = a -a b = b ] && echo and
    [ a = b -o b = b ] && echo or
    [ ! a = b ] && echo not
    """),
    ("for-loop", """
    for x in one two three; do echo "item $x"; done
    for x in a b c d
    do
      if [ $x = c ]; then continue; fi
      if [ $x = d ]; then break; fi
      echo $x
    done
    """),
    ("while-until", """
    i=0
    while [ $i -lt 4 ]; do
      echo "i=$i"
      i=$((i + 1))
    done
    j=3
    until [ $j -eq 0 ]; do
      j=$((j - 1))
      echo "j=$j"
    done
    """),
    ("case", """
    check() {
      case $1 in
        a) echo letter-a ;;
        [bc]) echo b-or-c ;;
        d|e) echo d-or-e ;;
        f*) echo starts-f ;;
        *) echo other ;;
      esac
    }
    check a; check b; check c; check e; check foo; check zzz
    """),
    ("functions", """
    greet() {
      echo "hello $1 and $2, $# args"
      return 3
    }
    greet mouse world
    echo "status $?"
    add() { echo $(($1 + $2)); }
    echo "sum $(add 20 22)"
    """),
    ("command-sub", """
    echo "one$(echo two)three"
    echo `echo backtick`
    echo $(echo nested $(echo deep))
    X=$(echo assigned)
    echo $X
    """),
    ("arithmetic", """
    echo $((3 * 4 + 1))
    echo $(( (2 + 3) * 4 ))
    x=10
    echo $((x / 3)) $((x % 3))
    echo $((x > 5)) $((x < 5)) $((x == 10))
    echo $((-4 + 2))
    """),
    ("brace-ops", """
    U=""
    echo "[${U:-default}]"
    echo "[${U:=assigned}]"
    echo "[$U]"
    V=set
    echo "[${V:+alt}]"
    echo "[${#V}]"
    P=/usr/local/bin/tool.tar.gz
    echo "${P##*/}"
    echo "${P#/usr}"
    echo "${P%%.*}"
    echo "${P%.gz}"
    """),
    ("positional", """
    set -- alpha beta gamma
    echo $1 $3 $#
    shift
    echo $1 $#
    set -- "with space" second
    echo "$1"
    """),
    ("status-chains", """
    false
    echo "after false $?"
    true && echo yes
    false || echo no
    false && echo hidden || echo fallback
    ! false && echo negated
    """),
    ("redirects", """
    echo first > out.txt
    cat out.txt
    echo second >> out.txt
    cat out.txt
    cat < out.txt
    """),
    ("glob-for", """
    touch aa.txt bb.txt cc.log
    for f in *.txt; do echo "got $f"; done
    echo *.log
    """),
    ("pipe-while-read", """
    printf 'red\\nblue\\ngreen\\n' | while read color; do echo "seen $color"; done
    """),
    ("while-read-file", """
    printf 'l1\\nl2\\n' > lines.txt
    while read line; do echo "line=$line"; done < lines.txt
    """),
    ("set-e", """
    set -e
    echo before
    false
    echo never
    """),
    ("eval-source", """
    eval "echo evaluated $((1+1))"
    echo 'echo sourced $1' > lib.sh
    . ./lib.sh arg1
    """),
    ("subscript", """
    echo 'echo "inner $1 of $#"' > inner.sh
    sh inner.sh alpha
    echo "back $?"
    """),
    ("dot-slash", """
    printf '#!/bin/sh\\necho ran with $1\\n' > run.sh
    chmod 755 run.sh
    ./run.sh flag
    """),
    ("comments-continuation", """
    # a comment
    echo one # trailing comments are words in msh and sh differs -- keep separate
    echo two \\
      three
    """),
    ("install-shaped", """
    set -e
    PREFIX=./opt
    detect() {
      case $(uname) in
        Darwin|Linux) echo supported ;;
        *) echo unsupported; exit 1 ;;
      esac
    }
    main() {
      echo "checking platform: $(detect)"
      mkdir -p "$PREFIX/bin"
      echo "fake-binary" > "$PREFIX/tool"
      chmod 755 "$PREFIX/tool"
      if [ -x "$PREFIX/tool" ]; then echo installed; fi
      PATH="$PREFIX:$PATH"
      export PATH
      echo "done"
    }
    main
    """),
]

@MainActor
func runMsh(_ script: String, workDir: URL) async -> (out: String, status: Int32) {
    let shell = MouseShell()
    let context = MouseShell.Context(root: workDir)
    try? script.write(to: workDir.appendingPathComponent("script.sh"), atomically: true, encoding: .utf8)
    let outputs = await shell.runProgram("sh script.sh", context: context, interactive: false)
    var out = outputs.filter { !$0.isError }.map(\.text).joined(separator: "\n")
    while out.hasSuffix("\n") { out.removeLast() }
    return (out, shell.lastStatus)
}

func runRealSh(_ script: String, workDir: URL) -> (out: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.currentDirectoryURL = workDir
    try? script.write(to: workDir.appendingPathComponent("script.sh"), atomically: true, encoding: .utf8)
    process.arguments = ["script.sh"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    var out = String(decoding: data, as: UTF8.self)
    while out.hasSuffix("\n") { out.removeLast() }
    return (out, process.terminationStatus)
}

var failures = 0
let base = FileManager.default.temporaryDirectory.appendingPathComponent("msh-verify-\(getpid())")

for (name, script) in corpus {
    // "comments-continuation" has a note in a trailing comment; strip it for sh fairness.
    let mshDir = base.appendingPathComponent("msh-\(name)")
    let shDir = base.appendingPathComponent("sh-\(name)")
    try? FileManager.default.createDirectory(at: mshDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: shDir, withIntermediateDirectories: true)

    let msh = await runMsh(script, workDir: mshDir)
    let real = runRealSh(script, workDir: shDir)
    if msh.out == real.out && msh.status == real.status {
        continue
    }
    failures += 1
    print("MISMATCH: \(name)")
    if msh.status != real.status { print("  status msh=\(msh.status) sh=\(real.status)") }
    if msh.out != real.out {
        print("  ---- msh ----\n\(msh.out)\n  ---- sh -----\n\(real.out)\n  -------------")
    }
}

try? FileManager.default.removeItem(at: base)
print(failures == 0 ? "ALL \(corpus.count) SCRIPTS MATCH /bin/sh" : "\(failures) MISMATCHES of \(corpus.count)")
exit(failures == 0 ? 0 : 1)
