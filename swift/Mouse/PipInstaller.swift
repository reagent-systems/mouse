import Foundation

/// `pip install`, the subset a wasi CPython can honour: pure-Python wheels.
///
/// The on-device Python has no pip and no ensurepip, and its wasi build cannot load a compiled
/// extension at all — so a real pip would mostly be a machine for producing confusing failures.
/// What CAN work is exactly this: a wheel is a zip (`ZipArchive` already reads those), PyPI's
/// JSON API is the registry, and a `py3-none-any` wheel unpacked into a site-packages directory
/// on `PYTHONPATH` is a working install. A package whose only wheels are compiled says so in one
/// line instead of failing at import time.
///
/// This is the first stage of embedding Hermes: the agent loop is pure Python, and the pieces
/// that are not get delegated to Mouse itself.
enum Pip {

    struct PipError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// Where installed wheels land: inside the python runtime's directory, which the shell
    /// mounts at `/usr/lib/python` — Runtimes.json puts `{root}/site-packages` on PYTHONPATH.
    static var sitePackages: URL {
        RuntimeStore.root.appendingPathComponent("python/site-packages", isDirectory: true)
    }

    /// Standard-library holes this wasi build has that PURE code can paper over at import
    /// time. Laid down whenever pip touches the site-packages dir and refreshed every time:
    /// `import ssl` is something half the ecosystem does defensively — asyncio itself pulls it
    /// in — and an import that explodes on arrival hides code that would run fine delegating
    /// its network to Mouse. USE of the shim refuses in words.
    private static let stdlibShims: [(file: String, source: String)] = [
        ("ssl.py", "# This CPython wasi build has no _ssl and can never load one. Python-side TLS does not\n# exist here BY DESIGN: network with TLS is Mouse's, reached through the agent's tools.\n# This shim exists so `import ssl` — which half the ecosystem does defensively — succeeds,\n# and any actual USE says what is going on instead of pretending.\nclass SSLError(OSError): pass\nclass SSLCertVerificationError(SSLError): pass\nclass SSLZeroReturnError(SSLError): pass\nclass SSLWantReadError(SSLError): pass\nclass SSLWantWriteError(SSLError): pass\nclass SSLSyscallError(SSLError): pass\nclass SSLEOFError(SSLError): pass\nCertificateError = SSLCertVerificationError\n\nCERT_NONE, CERT_OPTIONAL, CERT_REQUIRED = 0, 1, 2\nPROTOCOL_TLS, PROTOCOL_TLS_CLIENT, PROTOCOL_TLS_SERVER = 2, 16, 17\nHAS_SNI = False\nHAS_ALPN = False\nOP_NO_COMPRESSION = 0x20000\nOP_NO_TICKET = 0x4000\n\nclass TLSVersion:\n    MINIMUM_SUPPORTED = -2\n    TLSv1_2 = 771\n    TLSv1_3 = 772\n    MAXIMUM_SUPPORTED = -1\n\ndef _refuse(*_a, **_k):\n    raise SSLError(\"no TLS in this Python — network runs through Mouse's tools\")\n\nclass SSLContext:\n    def __init__(self, protocol=PROTOCOL_TLS_CLIENT, *a, **k):\n        self.protocol = protocol\n        self.check_hostname = True\n        self.verify_mode = CERT_REQUIRED\n        self.minimum_version = TLSVersion.TLSv1_2\n        self.maximum_version = TLSVersion.MAXIMUM_SUPPORTED\n        self.options = 0\n    def load_default_certs(self, *a, **k): pass\n    def load_verify_locations(self, *a, **k): pass\n    def load_cert_chain(self, *a, **k): pass\n    def set_ciphers(self, *a, **k): pass\n    def set_alpn_protocols(self, *a, **k): pass\n    def get_ca_certs(self, binary_form=False):\n        # Non-empty on purpose: hermes's ssl_guard treats an empty store as a broken\n        # install. The store is Mouse's URLSession trust, not this context's.\n        return [{\"subject\": (((\"commonName\", \"trust lives in Mouse\"),),)}]\n    def cert_store_stats(self):\n        return {\"x509\": 1, \"crl\": 0, \"x509_ca\": 1}\n    wrap_socket = _refuse\n    wrap_bio = _refuse\n\ndef create_default_context(*a, **k):\n    return SSLContext()\n\ndef _create_unverified_context(*a, **k):\n    return SSLContext()\n\nclass SSLObject: pass\nclass MemoryBIO:\n    def __init__(self): self._eof = False\n    @property\n    def pending(self): return 0\n    @property\n    def eof(self): return self._eof\n    def read(self, *a): return b\"\"\n    def write(self, *a): _refuse()\n    def write_eof(self): self._eof = True\n\nclass Purpose:\n    SERVER_AUTH = \"1.3.6.1.5.5.7.3.1\"\n    CLIENT_AUTH = \"1.3.6.1.5.5.7.3.2\"\n\nOPENSSL_VERSION = \"mouse-ssl-shim (no TLS; network is Mouse's)\"\nOPENSSL_VERSION_INFO = (0, 0, 0, 0, 0)\nOPENSSL_VERSION_NUMBER = 0\nCHANNEL_BINDING_TYPES = []\nVERIFY_DEFAULT = 0\nVERIFY_X509_STRICT = 0x20\nVERIFY_X509_TRUSTED_FIRST = 0x8000\ndef match_hostname(cert, hostname): _refuse()\ndef DER_cert_to_PEM_cert(der): _refuse()\ndef PEM_cert_to_DER_cert(pem): _refuse()\nclass SSLSocket:\n    def __getattr__(self, name): _refuse()\n\nwrap_socket = _refuse\nget_default_verify_paths = lambda: None\n"),
        ("webbrowser.py", "# Not in this wasi build's stdlib zip. There is no browser to open on this side anyway —\n# the container shows URLs to the user; opening one is a Mouse affordance, not Python's.\nclass Error(Exception): pass\n\ndef open(url, new=0, autoraise=True):\n    return False\ndef open_new(url): return open(url, 1)\ndef open_new_tab(url): return open(url, 2)\ndef get(using=None): raise Error(\"no browser inside the agent runtime\")\ndef register(*a, **k): pass\n"),
        ("ctypes/__init__.py", "# ctypes stand-in for wasm32-wasi (Mouse). CPython's wasi build ships no ctypes — the host\n# cannot load native code and never will. Importing succeeds so the ecosystem's OPTIONAL uses\n# (process titles, console tweaks, library probes) fall through their own except blocks; any\n# attempt to actually load or call a library raises OSError, which is what ctypes itself\n# raises for a library that is not there.\nclass ArgumentError(Exception): pass\n\ndef _refuse(*_a, **_k):\n    raise OSError(\"ctypes: no native libraries on wasm32-wasi (this Python runs inside Mouse)\")\n\nclass _Library:\n    def __init__(self, *a, **k): _refuse()\nCDLL = PyDLL = WinDLL = OleDLL = _Library\n\nclass _Loader:\n    def __getattr__(self, name): _refuse()\n    def LoadLibrary(self, name): _refuse()\ncdll = pydll = windll = oledll = _Loader()\n\nclass _SimpleCData:\n    _type_ = \"?\"\n    def __init__(self, value=None): self.value = value\n    def __repr__(self): return \"%s(%r)\" % (type(self).__name__, self.value)\ndef _simple(name, code):\n    return type(name, (_SimpleCData,), {\"_type_\": code})\nc_bool = _simple(\"c_bool\", \"?\"); c_char = _simple(\"c_char\", \"c\"); c_wchar = _simple(\"c_wchar\", \"u\")\nc_byte = _simple(\"c_byte\", \"b\"); c_ubyte = _simple(\"c_ubyte\", \"B\")\nc_short = _simple(\"c_short\", \"h\"); c_ushort = _simple(\"c_ushort\", \"H\")\nc_int = _simple(\"c_int\", \"i\"); c_uint = _simple(\"c_uint\", \"I\")\nc_long = _simple(\"c_long\", \"l\"); c_ulong = _simple(\"c_ulong\", \"L\")\nc_longlong = _simple(\"c_longlong\", \"q\"); c_ulonglong = _simple(\"c_ulonglong\", \"Q\")\nc_size_t = c_ulong; c_ssize_t = c_long\nc_float = _simple(\"c_float\", \"f\"); c_double = _simple(\"c_double\", \"d\"); c_longdouble = _simple(\"c_longdouble\", \"g\")\nc_char_p = _simple(\"c_char_p\", \"z\"); c_wchar_p = _simple(\"c_wchar_p\", \"Z\"); c_void_p = _simple(\"c_void_p\", \"P\")\nc_int8 = c_byte; c_uint8 = c_ubyte; c_int16 = c_short; c_uint16 = c_ushort\nc_int32 = c_int; c_uint32 = c_uint; c_int64 = c_longlong; c_uint64 = c_ulonglong\npy_object = _simple(\"py_object\", \"O\")\n\nclass Structure: _fields_ = []\nclass Union: _fields_ = []\nclass BigEndianStructure(Structure): pass\nclass LittleEndianStructure(Structure): pass\nclass Array: pass\nclass _Pointer: pass\ndef POINTER(cls): return type(\"LP_\" + getattr(cls, \"__name__\", \"type\"), (_Pointer,), {\"_type_\": cls})\ndef pointer(obj): _refuse()\ndef byref(obj, offset=0): _refuse()\ndef cast(obj, typ): _refuse()\ndef addressof(obj): _refuse()\ndef sizeof(obj): return 0\ndef alignment(obj): return 0\ndef resize(obj, size): _refuse()\ndef memmove(dst, src, count): _refuse()\ndef memset(dst, c, count): _refuse()\ndef string_at(ptr, size=-1): _refuse()\ndef wstring_at(ptr, size=-1): _refuse()\ndef create_string_buffer(init, size=None): _refuse()\ndef create_unicode_buffer(init, size=None): _refuse()\ndef get_errno(): return 0\ndef set_errno(value): return 0\ndef get_last_error(): return 0\ndef set_last_error(value): return 0\ndef CFUNCTYPE(restype, *argtypes, **kw): return lambda fn: fn\nWINFUNCTYPE = PYFUNCTYPE = CFUNCTYPE\ndef PyDLL_(*a, **k): _refuse()\nclass LibraryLoader:\n    def __init__(self, dlltype): self._dlltype = dlltype\n    def __getattr__(self, name): _refuse()\n    def LoadLibrary(self, name): _refuse()\npythonapi = _Loader()\nDEFAULT_MODE = 0\nRTLD_LOCAL = 0\nRTLD_GLOBAL = 0\n"),
        ("ctypes/util.py", "# ctypes.util for wasm32-wasi (Mouse): there are no shared libraries to find.\ndef find_library(name):\n    return None\ndef find_msvcrt():\n    return None\n"),
        ("fcntl.py", "# fcntl stand-in for wasm32-wasi (Mouse): there is no fcntl(2) here. File locks are the\n# common use (pid files, single-instance guards) and there is exactly one process on this\n# side, so locking is a no-op that succeeds; descriptor flag calls raise OSError, which is\n# what a platform without them would say.\nLOCK_SH, LOCK_EX, LOCK_NB, LOCK_UN = 1, 2, 4, 8\nF_DUPFD, F_GETFD, F_SETFD, F_GETFL, F_SETFL = 0, 1, 2, 3, 4\nF_GETLK, F_SETLK, F_SETLKW = 7, 8, 9\nF_RDLCK, F_WRLCK, F_UNLCK = 0, 1, 2\nFD_CLOEXEC = 1\ndef flock(fd, operation): return None\ndef lockf(fd, cmd, len=0, start=0, whence=0): return None\ndef fcntl(fd, cmd, arg=0):\n    raise OSError(\"fcntl: not available on wasm32-wasi (this Python runs inside Mouse)\")\ndef ioctl(fd, request, arg=0, mutate_flag=True):\n    raise OSError(\"ioctl: not available on wasm32-wasi (this Python runs inside Mouse)\")\n"),
        ("sitecustomize.py", "# Startup patches for holes in this wasi build, imported by `site` on every run.\n# wasi has no threads, and the build omits concurrent.futures.thread entirely. An executor\n# that runs the callable INLINE at submit() is the truthful single-threaded degradation:\n# same Future surface, work done on the only thread there is.\nimport sys, types\nimport concurrent.futures as _cf\n\n_thread_mod = types.ModuleType('concurrent.futures.thread')\n\nclass ThreadPoolExecutor(_cf.Executor):\n    def __init__(self, max_workers=None, thread_name_prefix=\"\", *a, **k):\n        self._shutdown = False\n    def submit(self, fn, /, *args, **kwargs):\n        future = _cf.Future()\n        try:\n            future.set_result(fn(*args, **kwargs))\n        except BaseException as error:\n            future.set_exception(error)\n        return future\n    def map(self, fn, *iterables, timeout=None, chunksize=1):\n        return map(fn, *iterables)\n    def shutdown(self, wait=True, *, cancel_futures=False):\n        self._shutdown = True\n\n_thread_mod.ThreadPoolExecutor = ThreadPoolExecutor\nsys.modules['concurrent.futures.thread'] = _thread_mod\n_cf.ThreadPoolExecutor = ThreadPoolExecutor\n\n# wasi has no threads at all — thread_create simply does not exist. Three truthful\n# degradations, by what the thread is FOR:\n#   a Timer never fires (it would otherwise block the only thread for its whole interval),\n#   a daemon thread pretends to start (they are watchers and keepalives),\n#   a non-daemon thread runs INLINE at start(), which is what one thread of execution means.\nimport threading as _threading\n\ndef _inline_start(self):\n    self._started.set()\n    if isinstance(self, _threading.Timer):\n        return\n    if self.daemon:\n        return\n    try:\n        self.run()\n    finally:\n        pass\n\n_threading.Thread.start = _inline_start\n"),
    ]

    static func layShims(in target: URL) {
        for shim in stdlibShims {
            let file = target.appendingPathComponent(shim.file)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? shim.source.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Install packages and their dependency closure. `names` accepts `name` or `name==1.2.3`.
    /// Every landed wheel is reported through `note`; already-present packages are skipped.
    ///
    /// A package that CANNOT land (no pure wheel) is fatal only when it was asked for by name.
    /// A transitive one is skipped and reported instead — one compiled dep deep in a closure
    /// used to abandon everything still queued behind it, so `openai` lost its own dependencies
    /// to hermes's pyyaml. Whether a skipped dep actually matters is measured at import time,
    /// which is a real answer; refusing the whole closure was a guess.
    static func install(_ names: [String], into destination: URL? = nil,
                        note: @escaping @Sendable (String) -> Void) async throws {
        let target = destination ?? sitePackages
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        layShims(in: target)
        let requested = Set(names.map { canonicalize(split($0).name) })
        var queue = names
        var seen: Set<String> = []
        var skipped: [String] = []
        while !queue.isEmpty {
            let spec = queue.removeFirst()
            let (name, pin) = split(spec)
            let canonical = canonicalize(name)
            guard seen.insert(canonical).inserted else { continue }
            // Substitutes come BEFORE the installed check so their adapter is refreshed on
            // every ask — an adapter that grows a missing name must reach installs that
            // already exist.
            if let substitute = substitutes[canonical] {
                note("\(canonical) has no pure wheel — installing \(substitute.install) in its place")
                queue.append(substitute.install)
                if let file = substitute.adapterFile, let source = substitute.adapterSource {
                    try source.write(to: target.appendingPathComponent(file),
                                     atomically: true, encoding: .utf8)
                }
                // A dist-info of its own, so "is pyyaml here" answers yes and the closure never
                // asks again.
                let dist = target.appendingPathComponent("\(canonical)-0.0.0.substituted.dist-info")
                try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
                try "Metadata-Version: 2.1\nName: \(canonical)\nVersion: 0.0.0.substituted\n"
                    .write(to: dist.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8)
                continue
            }
            if installed(canonical, in: target) {
                note("\(canonical) is already installed")
                continue
            }
            do {
                let wheel = try await resolve(canonical, pin: pin)
                note("fetching \(canonical) \(wheel.version) (\(wheel.size / 1024) kB)")
                let data = try await download(wheel.url)
                try ZipArchive.extract(data, to: target)
                note("installed \(canonical) \(wheel.version)")
                // The wheel's own METADATA names what it needs. Markered requirements (extras,
                // other platforms, older pythons) are skipped whole: the one platform this runs
                // on is the one no marker anticipates, and an extra is opt-in by definition.
                queue.append(contentsOf: try requirements(of: canonical, version: wheel.version, in: target))
            } catch where !requested.contains(canonical) {
                skipped.append(canonical)
                note("skipped \(canonical): \("\(error)".replacingOccurrences(of: "pip: ", with: ""))")
            }
        }
        if !skipped.isEmpty {
            note("skipped \(skipped.count): \(skipped.joined(separator: ", ")) — imports needing them will say so")
        }
    }

    // MARK: - Substitutes

    /// The Python face of the house substitution pattern (`rollup` -> `@rollup/wasm-node`):
    /// a package that only exists compiled, replaced by a pure-published equivalent under the
    /// importable name the requester's code actually uses.
    ///
    /// pyyaml is the one that matters today — hermes's `utils.py` does `import yaml` on its
    /// first page — and ruamel.yaml is no stranger standing in: it BEGAN as a PyYAML fork,
    /// hermes already pins it, and its author publishes it pure. The adapter is the PyYAML
    /// surface callers actually use, expressed as ruamel calls.
    private static let substitutes: [String: (install: String, adapterFile: String?, adapterSource: String?)] = [
        "pyyaml": ("ruamel.yaml", "yaml.py", "# pyyaml has no pure-Python wheel, and this Python cannot load compiled extensions.\n# Installed by Mouse's pip as the `yaml` module: PyYAML's common surface over\n# ruamel.yaml (itself a PyYAML fork), which is pure and installed alongside.\nfrom ruamel.yaml import YAML as _YAML\nfrom ruamel.yaml.error import YAMLError  # noqa: F401  (PyYAML's name, re-exported)\nimport io as _io\n\ndef _load(stream, typ):\n    data = stream.read() if hasattr(stream, \"read\") else stream\n    return _YAML(typ=typ, pure=True).load(data)\n\ndef safe_load(stream): return _load(stream, \"safe\")\ndef load(stream, Loader=None): return _load(stream, \"safe\" if Loader is None else \"unsafe\")\ndef full_load(stream): return _load(stream, \"unsafe\")\n\ndef safe_load_all(stream):\n    data = stream.read() if hasattr(stream, \"read\") else stream\n    return _YAML(typ=\"safe\", pure=True).load_all(data)\n\ndef _dump(data, stream, typ, **kw):\n    yml = _YAML(typ=typ, pure=True)\n    yml.default_flow_style = kw.get(\"default_flow_style\", False)\n    if stream is None:\n        out = _io.StringIO()\n        yml.dump(data, out)\n        return out.getvalue()\n    yml.dump(data, stream)\n    return None\n\ndef safe_dump(data, stream=None, **kw): return _dump(data, stream, \"safe\", **kw)\ndef dump(data, stream=None, **kw): return _dump(data, stream, \"rt\", **kw)\n\nclass SafeLoader:  # noqa: N801 — PyYAML's names, kept for isinstance/subclass users\n    pass\nclass Loader(SafeLoader):\n    pass\n\nclass SafeDumper:  # subclassed in the wild (hermes's IndentDumper); representers are a no-op\n    @classmethod\n    def add_representer(cls, data_type, representer):\n        pass\nclass Dumper(SafeDumper):\n    pass\n\ndef add_representer(data_type, representer, Dumper=Dumper):\n    pass\n"),
    ]

    // MARK: - The registry

    private struct Wheel {
        let url: URL
        let version: String
        let size: Int
    }

    /// PyPI's JSON API. A pinned version asks for that release; otherwise the latest. Only a
    /// pure wheel (`…-none-any.whl`) is acceptable — anything else needs a compiled extension
    /// this Python can never load, and the error says that rather than "not found".
    private static func resolve(_ name: String, pin: String?) async throws -> Wheel {
        let path = pin.map { "pypi/\(name)/\($0)/json" } ?? "pypi/\(name)/json"
        guard let url = URL(string: "https://pypi.org/\(path)") else {
            throw PipError("pip: \(name) is not a package name")
        }
        let data = try await download(url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["urls"] as? [[String: Any]],
              let info = json["info"] as? [String: Any],
              let version = info["version"] as? String else {
            throw PipError("pip: no such package: \(name)" + (pin.map { "==\($0)" } ?? ""))
        }
        for file in files {
            guard let filename = file["filename"] as? String,
                  filename.hasSuffix("-none-any.whl"),
                  let location = file["url"] as? String,
                  let wheelURL = URL(string: location) else { continue }
            return Wheel(url: wheelURL, version: version, size: file["size"] as? Int ?? 0)
        }
        throw PipError("pip: \(name) \(version) has no pure-Python wheel — it needs a compiled "
            + "extension, which this Python cannot load")
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PipError("pip: \(url.host ?? "pypi") answered \(http.statusCode) for \(url.lastPathComponent)")
        }
        return data
    }

    // MARK: - The wheel's own manifest

    /// `Requires-Dist` from the unpacked `*.dist-info/METADATA`, minus anything markered.
    private static func requirements(of name: String, version: String, in target: URL) throws -> [String] {
        guard let metadata = metadataFile(name, in: target) else { return [] }
        let text = try String(contentsOf: metadata, encoding: .utf8)
        var wanted: [String] = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("Requires-Dist:") else { continue }
            let requirement = line.dropFirst("Requires-Dist:".count).trimmingCharacters(in: .whitespaces)
            guard !requirement.contains(";") else { continue }   // markered: extras, other platforms
            // "urllib3 (<3,>=1.21.1)" or "idna>=2.5" — the name stops at the first non-name char.
            let depName = requirement.prefix { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            if !depName.isEmpty { wanted.append(String(depName)) }
        }
        return wanted
    }

    private static func installed(_ name: String, in target: URL) -> Bool {
        metadataFile(name, in: target) != nil
    }

    /// The dist-info directory a wheel of `name` leaves behind, at any version. Wheel directory
    /// names use `_` where the package name has `-`.
    private static func metadataFile(_ name: String, in target: URL) -> URL? {
        let stem = name.replacingOccurrences(of: "-", with: "_").lowercased()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        for entry in entries where entry.lowercased().hasPrefix(stem + "-") && entry.hasSuffix(".dist-info") {
            let file = target.appendingPathComponent(entry).appendingPathComponent("METADATA")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    // MARK: - Names

    /// PEP 503: comparisons happen on the lowercased name with runs of `-`, `_`, `.` as one `-`.
    static func canonicalize(_ name: String) -> String {
        var out = ""
        var dash = false
        for character in name.lowercased() {
            if "-_.".contains(character) {
                dash = true
            } else {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.append(character)
            }
        }
        return out
    }

    /// `name==1.2.3` → (name, pin). Other operators are refused rather than misread: this
    /// installer resolves exact pins and latest, and pretending `>=` resolved would install
    /// something the requester did not ask for.
    static func split(_ spec: String) -> (name: String, pin: String?) {
        if let range = spec.range(of: "==") {
            return (String(spec[..<range.lowerBound]), String(spec[range.upperBound...]))
        }
        return (spec, nil)
    }
}
