'use strict';
// CPython, through `node:wasi`, on this engine. python.wasm imports NOTHING but
// wasi_snapshot_preview1 — 42 functions, every one of which this engine already implements — so
// the question is not "could it work in principle" but "does a real 30 MB language runtime
// actually run": does the module instantiate, does the interpreter reach its own stdlib on disk,
// does it compute, and does its exit status mean what it says.
//
// Results travel through a FILE in a preopened directory rather than through fd 1. That is not
// squeamishness about stdout — it makes each case's output unambiguous and readable back in the
// same process, and it exercises path_open/fd_write/fd_read on a real directory at the same time.
const fs = require('fs');
const path = require('path');
const { WASI } = require('node:wasi');

// Both paths come from the environment because they are not the same on both hosts: under real
// node they are real paths on disk, and under this engine they are virtual paths inside a mounted
// runtime — the engine's filesystem is rooted, so a host path outside the root does not exist.
const home = process.env.MOUSE_PYTHON_HOME;
const wasmPath = process.env.MOUSE_PYTHON_WASM;
function line(name, value) { console.log(name + '\t' + value); }

// Each case is a fresh interpreter: CPython calls proc_exit, and a WASI instance is spent once
// it has exited.
function runPython(args, files) {
  // Relative to the cwd rather than TMPDIR: this engine's filesystem is rooted at the workspace,
  // so a host temp directory is not a place it can reach.
  const root = fs.mkdtempSync('pyrun-');
  for (const name of Object.keys(files || {})) {
    fs.writeFileSync(path.join(root, name), files[name]);
  }
  const wasi = new WASI({
    version: 'preview1',
    args: ['python'].concat(args),
    // PYTHONHOME points at the stdlib the release ships; without it the interpreter starts and
    // then cannot import so much as `encodings`, which is the first failure everyone hits.
    env: { PYTHONHOME: '/lib', PYTHONPATH: '/lib/python3.14', PYTHONDONTWRITEBYTECODE: '1' },
    preopens: { '/lib': home, '/work': path.resolve(root) },
    returnOnExit: true,
  });
  const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)),
                                            wasi.getImportObject());
  const code = wasi.start(instance);
  let said = '';
  try { said = fs.readFileSync(path.join(root, 'out.txt'), 'utf8'); } catch (error) { said = ''; }
  fs.rmSync(root, { recursive: true, force: true });
  return { code: code, said: said.trim() };
}

function attempt(name, args, files) {
  try {
    const result = runPython(args, files);
    line(name, 'exit=' + result.code + ' said=' + JSON.stringify(result.said));
  } catch (error) {
    line(name, 'THREW ' + (error && (error.name + ': ' + error.message)));
  }
}

line('artifact-present', String(fs.existsSync(wasmPath)));

// The interpreter runs at all, and `-c` reaches the filesystem it was given.
attempt('dash-c', ['-c', 'open("/work/out.txt","w").write("hello from python")']);

// A script FILE, and the interpreter's own view of what it is running on.
attempt('script-file', ['/work/hello.py'], {
  'hello.py': 'import sys\nopen("/work/out.txt","w").write(sys.platform + " " + sys.version.split()[0])\n',
});

// The shipped stdlib — the thing PYTHONHOME exists for. json and math are C extensions built
// into the binary; textwrap is pure Python read off disk, so this needs both halves.
attempt('stdlib-import', ['-c',
  'import json, math, textwrap\n'
  + 'open("/work/out.txt","w").write(json.dumps({"root": math.isqrt(144), "wrapped": textwrap.wrap("a b c", 3)}))']);

// Real computation, not just a banner.
attempt('computes', ['-c',
  'open("/work/out.txt","w").write(str(sum(i*i for i in range(1000))))']);

// A non-zero exit must arrive as a status, not as a throw and not as success.
attempt('exit-status', ['-c', 'import sys; open("/work/out.txt","w").write("before"); sys.exit(3)']);

// An uncaught exception is exit 1, and the interpreter still ran.
attempt('traceback-status', ['-c', 'open("/work/out.txt","w").write("ran"); raise ValueError("boom")']);

// Reading a file the host wrote, then writing one back: path_open in both directions.
attempt('file-round-trip', ['/work/copy.py'], {
  'copy.py': 'data = open("/work/input.txt").read()\nopen("/work/out.txt","w").write(data.upper())\n',
  'input.txt': 'round trip',
});
