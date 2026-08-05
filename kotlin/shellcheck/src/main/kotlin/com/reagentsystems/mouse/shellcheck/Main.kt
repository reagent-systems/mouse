package com.reagentsystems.mouse.shellcheck

import com.reagentsystems.mouse.shell.MouseShell
import java.io.File

/**
 * Phase A verification, and a straight port of `verify/shell/main.swift` — the SAME 25 scripts, in
 * the same order, compared the same way. Each script runs through msh (via its own `sh` script
 * path, which captures raw stdout) and through the real `/bin/sh`, then stdout + exit status are
 * compared. Each side gets its own scratch directory.
 *
 * Differential is the whole point. A shell checked against expectations someone typed by hand only
 * proves it is self-consistent; checked against `/bin/sh` it proves the grammar is the one real
 * scripts are written in. When msh and `/bin/sh` disagree, one of them is wrong, and it is not
 * `/bin/sh`.
 *
 * The corpus is duplicated rather than read from `verify/shell/main.swift` because it is Swift
 * source, not a fixture — `:screencheck` reads `verify/` fixtures directly precisely because those
 * ARE data. Drift is caught by the two harnesses reporting different script counts.
 */

/** `$` in a raw string, spelled out only where Kotlin would otherwise read a template. */
private const val D = "\$"

private val corpus: List<Pair<String, String>> = listOf(
    "echo" to """
        echo hi
        echo a b   c
    """.trimIndent(),

    "quoting" to """
        echo "a  b" 'c  d' e\ f
        echo "mixed 'inner'" 'and "outer"'
    """.trimIndent(),

    "vars" to """
        X=5
        echo ${D}X
        Y="a b"
        echo "${D}Y"
        echo ${D}{Y}z
    """.trimIndent(),

    "field-splitting" to """
        X="a  b c"
        set -- ${D}X
        echo $#
        echo "${D}Y" | cat
    """.trimIndent(),

    "if-elif-else" to """
        if [ 3 -gt 2 ]; then echo bigger; fi
        if [ a = b ]; then echo no; elif [ -n hi ]; then echo elif; else echo else; fi
        if [ a = b ]
        then
          echo no
        else
          echo multiline
        fi
    """.trimIndent(),

    "test-ops" to """
        [ -z "" ] && echo empty
        [ -n "x" ] && echo nonempty
        [ 5 -le 5 ] && echo le
        [ abc != abd ] && echo ne
        test 1 -lt 2 && echo lt
        [ a = a -a b = b ] && echo and
        [ a = b -o b = b ] && echo or
        [ ! a = b ] && echo not
    """.trimIndent(),

    "for-loop" to """
        for x in one two three; do echo "item ${D}x"; done
        for x in a b c d
        do
          if [ ${D}x = c ]; then continue; fi
          if [ ${D}x = d ]; then break; fi
          echo ${D}x
        done
    """.trimIndent(),

    "while-until" to """
        i=0
        while [ ${D}i -lt 4 ]; do
          echo "i=${D}i"
          i=$((i + 1))
        done
        j=3
        until [ ${D}j -eq 0 ]; do
          j=$((j - 1))
          echo "j=${D}j"
        done
    """.trimIndent(),

    "case" to """
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
    """.trimIndent(),

    "functions" to """
        greet() {
          echo "hello $1 and $2, $# args"
          return 3
        }
        greet mouse world
        echo "status $?"
        add() { echo $(($1 + $2)); }
        echo "sum $(add 20 22)"
    """.trimIndent(),

    "command-sub" to """
        echo "one$(echo two)three"
        echo `echo backtick`
        echo $(echo nested $(echo deep))
        X=$(echo assigned)
        echo ${D}X
    """.trimIndent(),

    "arithmetic" to """
        echo $((3 * 4 + 1))
        echo $(( (2 + 3) * 4 ))
        x=10
        echo $((x / 3)) $((x % 3))
        echo $((x > 5)) $((x < 5)) $((x == 10))
        echo $((-4 + 2))
    """.trimIndent(),

    "brace-ops" to """
        U=""
        echo "[${D}{U:-default}]"
        echo "[${D}{U:=assigned}]"
        echo "[${D}U]"
        V=set
        echo "[${D}{V:+alt}]"
        echo "[${D}{#V}]"
        P=/usr/local/bin/tool.tar.gz
        echo "${D}{P##*/}"
        echo "${D}{P#/usr}"
        echo "${D}{P%%.*}"
        echo "${D}{P%.gz}"
    """.trimIndent(),

    "positional" to """
        set -- alpha beta gamma
        echo $1 $3 $#
        shift
        echo $1 $#
        set -- "with space" second
        echo "$1"
    """.trimIndent(),

    "status-chains" to """
        false
        echo "after false $?"
        true && echo yes
        false || echo no
        false && echo hidden || echo fallback
        ! false && echo negated
    """.trimIndent(),

    "redirects" to """
        echo first > out.txt
        cat out.txt
        echo second >> out.txt
        cat out.txt
        cat < out.txt
    """.trimIndent(),

    "glob-for" to """
        touch aa.txt bb.txt cc.log
        for f in *.txt; do echo "got ${D}f"; done
        echo *.log
    """.trimIndent(),

    "pipe-while-read" to
        """printf 'red\nblue\ngreen\n' | while read color; do echo "seen ${D}color"; done""",

    "while-read-file" to """
        printf 'l1\nl2\n' > lines.txt
        while read line; do echo "line=${D}line"; done < lines.txt
    """.trimIndent(),

    "set-e" to """
        set -e
        echo before
        false
        echo never
    """.trimIndent(),

    // `. file` only — NO operands after it. POSIX leaves arguments to the dot utility
    // UNSPECIFIED, and the two /bin/sh implementations this corpus actually runs against disagree:
    // bash (macOS /bin/sh) sets $1 for the sourced file, dash (Ubuntu /bin/sh) ignores the operand
    // entirely. The corpus was green for a year because it had only ever been run on macOS; the
    // first CI run on Linux reported `sourced arg1` against `sourced` and was RIGHT to.
    //
    // msh follows bash here, which is a defensible choice and is not what this case is for. A
    // gate whose expected output depends on which sh the machine happens to ship is not gating
    // the shell language, it is gating the machine.
    "eval-source" to """
        eval "echo evaluated $((1+1))"
        echo 'echo sourced' > lib.sh
        . ./lib.sh
    """.trimIndent(),

    "subscript" to """
        echo 'echo "inner $1 of $#"' > inner.sh
        sh inner.sh alpha
        echo "back $?"
    """.trimIndent(),

    "dot-slash" to """
        printf '#!/bin/sh\necho ran with $1\n' > run.sh
        chmod 755 run.sh
        ./run.sh flag
    """.trimIndent(),

    "comments-continuation" to """
        # a comment
        echo one # trailing comments are words in msh and sh differs -- keep separate
        echo two \
          three
    """.trimIndent(),

    "install-shaped" to """
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
          mkdir -p "${D}PREFIX/bin"
          echo "fake-binary" > "${D}PREFIX/tool"
          chmod 755 "${D}PREFIX/tool"
          if [ -x "${D}PREFIX/tool" ]; then echo installed; fi
          PATH="${D}PREFIX:${D}PATH"
          export PATH
          echo "done"
        }
        main
    """.trimIndent(),
)

private fun runMsh(script: String, workDir: File): Pair<String, Int> {
    val shell = MouseShell()
    val context = MouseShell.Context(root = workDir)
    File(workDir, "script.sh").writeText(script)
    val outputs = shell.runProgram("sh script.sh", context, interactive = false)
    val out = outputs.filter { !it.isError }.joinToString("\n") { it.text }.trimEnd('\n')
    return out to shell.lastStatus
}

private fun runRealSh(script: String, workDir: File): Pair<String, Int> {
    File(workDir, "script.sh").writeText(script)
    val process = ProcessBuilder("/bin/sh", "script.sh")
        .directory(workDir)
        // Discarded, not merged: the comparison is stdout only, and a merged stderr would make
        // msh's diagnostics look like output.
        .redirectError(ProcessBuilder.Redirect.DISCARD)
        .start()
    val out = process.inputStream.readBytes().toString(Charsets.UTF_8).trimEnd('\n')
    return out to process.waitFor()
}

fun main() {
    if (!File("/bin/sh").canExecute()) {
        println("SHELL LANGUAGE: no /bin/sh on this machine — the differential gate cannot run")
        kotlin.system.exitProcess(1)
    }

    var failures = 0
    val base = File(System.getProperty("java.io.tmpdir"), "msh-verify-${ProcessHandle.current().pid()}")

    for ((name, script) in corpus) {
        val mshDir = File(base, "msh-$name")
        val shDir = File(base, "sh-$name")
        mshDir.mkdirs()
        shDir.mkdirs()

        val msh = runMsh(script, mshDir)
        val real = runRealSh(script, shDir)
        if (msh.first == real.first && msh.second == real.second) continue

        failures++
        println("MISMATCH: $name")
        if (msh.second != real.second) println("  status msh=${msh.second} sh=${real.second}")
        if (msh.first != real.first) {
            println("  ---- msh ----\n${msh.first}\n  ---- sh -----\n${real.first}\n  -------------")
        }
    }

    base.deleteRecursively()
    println(
        if (failures == 0) {
            "SHELL LANGUAGE: ${corpus.size} scripts — quoting, vars, if/elif/else, for, while/until, " +
                "case, functions, test/[, command substitution, arithmetic, \${} ops, positionals, " +
                "redirects, globs, read, set -e, eval/source/sh, ./script — MATCH /bin/sh"
        } else {
            "$failures MISMATCHES of ${corpus.size}"
        },
    )
    kotlin.system.exitProcess(if (failures == 0) 0 else 1)
}
