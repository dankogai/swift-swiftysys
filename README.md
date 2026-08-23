# swift-swiftysys

[![CI via GitHub Actions](https://github.com/dankogai/swift-swiftysys/actions/workflows/swift.yml/badge.svg)](https://github.com/dankogai/swift-swiftysys/actions/workflows/swift.yml)

System programming made Swifty — as easy as Perl, Python, or Ruby, yet
swifty. Four pillars, Ruby's split with Perl's soul:

- **`FS`** — the *namespace* view: filesystem nodes as a value-type enum,
  chainable without force-unwrapping, in the spirit of [SwiftyJSON].
- **`IO`** — the *stream* view: open file descriptors as reference types —
  files, pipes to processes (Perl's 2-arg `open`, `IO.qx()`, and
  `IPC::Open3` included), and, on the roadmap, sockets.
- **`Sys`** — the *process* view: Python's `sys` plus the Perl core
  variables every script reaches for — `argv`, `env`, `exit`, `pid`,
  `platform`, `uname`, and friends.
- **`IO.HTTPS`** (and **`IO.HTTP`**) — the *web* view: REST verbs on
  chainable URLs. HTTPS carries encryption and CA verification — so it
  gets its own type, TLS-only by construction, namespaced under `IO`
  so protocols live as siblings. `IO.HTTP` is its plaintext sibling
  for the intranet.

[SwiftyJSON]: https://github.com/SwiftyJSON/SwiftyJSON

```swift
import SwiftySys

// ---- FS: nodes ----
FS("/etc/hosts")        // FS.file(/etc/hosts)
FS("/nonexistent")      // FS.error(ENOENT, /nonexistent)

let node = FS("/tmp")["a"]["b.txt"]   // chain — no `!`, no `?`, no `try`
node.string             // String?  — nil on error
node.stringValue        // String   — "" on error
try node.read()         // Data     — throws the Errno
node.size               // Int64?
node.mtime              // Date?
node.error              // Errno?   — what went wrong, if anything

for (name, node) in FS("/var/log") {  // directories iterate like [String: FS]
    print(name, node.sizeValue)
}

FS("/tmp")["hello.txt"] = "hello, world\n"    // = writes...
FS("/tmp")["hello.txt"] += "goodbye\n"        // ...+= appends
try FS("/tmp")["a"]["b"]["c"].mkdir(withIntermediates: true)
try FS("/tmp")["a"].remove(recursively: true)

// ---- IO: streams ----
let out = try IO.open("> /tmp/out.txt")     // Perl-style 2-arg open
try out.write("hello\n")
try out.close()

let sorted = try IO.open("sort -u /tmp/words.txt |")   // read from a command
print(try sorted.readString())

let sink = try IO.open("| wc -l")           // write to a command
try sink.write("a\nb\nc\n")
try sink.close()                            // waits; exit status returned

try IO.qx("uname -a")                          // Perl's backticks

// ---- redirection operators, noclobber manners ----
try FS("draft.txt") > "final.txt"           // write; throws if target exists
try FS("draft.txt") >! "final.txt"          // csh's >! — clobbers
try FS("/var/log/a.log") >> "all.log"       // append; target must exist
try IO.open("make 2>&1 |") >>! "build.log"  // append; creates if absent

// ---- HTTPS: the secure web ----
try IO.HTTPS("example.com").get().bodyString            // that's a GET
try IO.HTTPS("api.github.com")["users"]["dankogai"]     // chain paths, FS-style
    .get().validate().bodyString
try IO.HTTPS("api.example").header("Authorization", "Bearer \(token)")
    .post(#"{"answer": 42}"#)                        // REST verbs
try IO.HTTP("intranet.local:8080").get()             // plaintext, by type choice

// ---- Sys: the process ----
Sys.argv                                    // [String] — sys.argv / @ARGV
Sys.env["HOME"]                             // String?  — %ENV
Sys.env["DEBUG"] = "1"                      // setenv
Sys.pid                                     // $$
Sys.platform                                // "darwin" | "linux"
Sys.uname.machine                           // "arm64", "x86_64", ...
Sys.exit(0)                                 // sys.exit

// ---- and they meet ----
let log = try FS.temp["build.log"].open(.append)   // FS node → IO stream
Sys.executable                                     // the running binary, as an FS node
```

## `FS` — the namespace

### One type, eight cases

```swift
public enum FS {
    case file(FilePath)
    case directory(FilePath)
    case symlink(FilePath)
    case fifo(FilePath)
    case socket(FilePath)
    case blockDevice(FilePath)
    case characterDevice(FilePath)
    case error(Errno, FilePath)     // errno + WHERE it failed
}
```

`FS(_:)` performs a single `lstat(2)` and picks the case. Symlinks are
not followed — a symlink reports as `.symlink`; use `resolved()` to
follow it. (`FilePath` and `Errno` come from Apple's [swift-system],
re-exported for your convenience.)

[swift-system]: https://github.com/apple/swift-system

### Error propagation

Subscripting a node that is already `.error` propagates the error, so
chains are always safe. The error carries the *path where the failure
occurred*, with one deliberate refinement per errno:

- `ENOENT` **extends**: `FS("/tmp")["no"]["such"]["file.txt"]` is
  `.error(ENOENT, /tmp/no/such/file.txt)` — the full intended path, so a
  `write(_:)`, `mkdir(withIntermediates: true)`, or `open(.write)` at
  the end of the chain knows where to create.
- Everything else **freezes at the origin**:
  `FS("/etc/passwd")["x"]["y"]` is `.error(ENOTDIR, /etc/passwd)` —
  it reports where things went wrong, not some phantom descendant.

### Terminal accessors, SwiftyJSON style

| optional (`nil` on error) | non-optional (empty on error) | throwing |
|---------------------------|-------------------------------|----------|
| `data: Data?`             | `dataValue: Data`             | `read()` |
| `string: String?`         | `stringValue: String`         | `readString()` |
| `size: Int64?`            | `sizeValue: Int64`            |          |

Plus `mtime`, `atime`, `ctime`, `mode`, `permissions`, `uid`, `gid`,
`nlink`, `inode`, `device` — all `Optional`, all computed from a fresh
`lstat(2)` at each access (so they track the disk even if the enum case
has gone stale; `refreshed()` re-examines the case itself).

### Directories as dictionaries

`FS` conforms to `Sequence`, yielding `(name: String, node: FS)` pairs
sorted by name. Non-directories (including `.error`) yield nothing, so
iteration never throws. `keys`, `children`, and `count` come along, and
`filter` / `map` / `contains` come for free — which is where Swift
starts to beat Perl.

### Mutation

`write`, `append`, `mkdir`, `remove`, and `symlink(to:)` all throw
`Errno` on failure and return the fresh node on success
(`@discardableResult`).

The classic POSIX manipulation calls follow the same shape:

```swift
try FS("script.sh").chmod(0o755)          // or chmod([.ownerReadWrite])
try FS("script.sh").chmod("u+x")          // or chmod(1)'s symbolic modes:
try FS("shared").chmod("a=rwX")           // who ugoa, ops +-=, perms rwxXst,
try FS("f").chmod("u=rwx,go=rx")          // permcopy ("g=u"), clauses compose
try FS("data.log").chown(user: "dankogai")  // or chown(uid:gid:), by id
try FS("draft.txt").rename(to: "final.txt")
try FS("original").link(to: "mirror")     // hard link — link(2)
try FS("f").utime(mtime: someDate)        // utimes(2); no args = now
try FS.temp["stamp"].touch()              // creates or freshens
try FS("big.log").truncate(to: 0)
try FS.temp["pipe"].mkfifo()              // a .fifo is born
```

The process-global pair lives on `Sys`, where process state belongs:
`Sys.chdir(path_or_node)` and `Sys.umask(mask)` (returns the previous
mask).

### Assignment sugar

The dictionary metaphor goes all the way — `=` writes, `+=` appends:

```swift
FS("/tmp")["hello.txt"] = "hello, world\n"   // write (create/truncate)
FS("/tmp")["hello.txt"] += "goodbye\n"        // append (creates if absent)
FS("/tmp")["blob.bin"]  = someData            // Data works too
FS("/tmp")["copy.txt"]  = FS("/etc/hosts")    // assign a node = copy it
let s: String? = FS("/tmp")["hello.txt"]      // the typed getter reads
try FS("/tmp")["hello.txt"].remove()          // deleting stays explicit
```

No `var` needed anywhere: the setters are `nonmutating` (the disk
mutates, not the enum), so this works on freshly-constructed rvalues.
Swift cannot overload plain `=`, but a subscript setter gets the exact
same syntax.

The sugar is best-effort, SwiftyJSON style: setters cannot throw, so
failures are silent — but never invisible, since the target node's
`error` tells you what happened. Use the throwing `write(_:)` /
`append(_:)` when you want errors raised.

Deletion is deliberately *not* sugared: assigning `nil` is a no-op.
`rm` is the one operation that deserves to look like what it is —
`remove()`.

## `IO` — the streams

`IO` is a `class` (it owns a live file descriptor) with explicit
primitives and Perl sugar on top:

```swift
// explicit — use these when anything is not a literal
IO.open(path, .read)                       // Mode is an OptionSet:
IO.open(path, [.read, .write])             // ...so modes compose
IO.open(path, [.read, .append])            // read anywhere, write at the end
IO.popen(command, .read)                   // via /bin/sh -c (.read or .write)
IO.readPipe(from: ["ls", "-la", path])     // "cmd |"  — argv, NO shell
IO.writePipe(to: ["sort", "-o", output])   // "| cmd"  — argv, NO shell
IO.open3(argv) / IO.open3(command)         // stdin + stdout + stderr

// Perl-style 2-arg open — sugar for literals
IO.open("< in.txt")        // read (the "<" is optional)
IO.open("> out.txt")       // create/truncate
IO.open(">> log.txt")      // create/append
IO.open("| sort -u")       // pipe: write to command's stdin
IO.open("ls -la |")        // pipe: read command's stdout
IO.open("https://example.com")    // URL: GET — read the body
IO.open("| https://api.example")  // URL: POST what you write, on close()
```

`readPipe(from:)` / `writePipe(to:)` are Perl's safer *list-form* open
(`open $fh, "-|", @cmd` / `open $fh, "|-", @cmd`): the argv is executed
directly — `argv[0]` resolved against `PATH`, execvp(3)-style — so
arguments arrive verbatim and there is nothing to inject.

### open3 — stdout and stderr, separately

`IO.open3` is Perl's `IPC::Open3`: a child with all three standard
streams piped, taking either an argv list (no shell) or a command
string (via `/bin/sh -c`):

```swift
let p = try IO.open3(["make", "-j8"])
try p.stdin.close()
let out = try p.stdout.readString()
let err = try p.stderr.readString()
p.close()                        // waits; exit status (Perl's $?)
```

Reading one pipe to EOF while the other fills is open3's classic
deadlock — so when you just want everything, use `capture`, which
multiplexes all three descriptors with `poll(2)` on a single thread;
no amount of output on either stream can wedge the child:

```swift
let r = try IO.open3(["cc", "-c", "broken.c"]).capture()
r.stdoutString                   // captured stdout
r.stderrString                   // the diagnostics you wanted
r.status                         // exit status
try IO.open3(["tr", "a-z", "A-Z"]).capture(stdin: "feed me\n")
```

Reading and writing: `read(_ count:)`, `readAll()`, `readString()`,
`write(Data)`, `write(String)`. `close()` is idempotent; for pipes it
waits for the process and returns the exit status (also kept in
`terminationStatus`) — Perl's `close` setting `$?`. `IO.stdin` /
`.stdout` / `.stderr` wrap the standard descriptors.

`IO.qx(_:)` is the backtick: runs a command through the shell and returns
its stdout as a `String`.

> **A word on the magic.** Interpolating untrusted strings into a 2-arg
> open spec is the same injection Perl is famous for — that is *why*
> Perl grew 3-arg open and the list-form pipe. The sugar is for
> literals; `readPipe(from:)` / `writePipe(to:)` are right there for
> everything else.

### URLs — Ruby's open-uri

`IO.open` takes URLs too, backed by Foundation's `URLSession`
(synchronous by design — this is a scripting kit):

```swift
let page = try IO.open("https://example.com")        // GET, now
try page.readString()                                 // the body
page.terminationStatus                                // HTTP 200

let post = try IO.open(URL(string: "https://api.example/submit")!,
                       .write, method: "PUT", timeout: 30)
try post.write(payload)
try post.close()          // uploads here; returns the HTTP status
```

Reading fetches the body at `open` and serves it through a real
descriptor, so every `IO` primitive works on it. Writing buffers and
uploads at `close()` — `POST` unless `method` says otherwise. Non-2xx
responses throw `IO.HTTPError` (with `status` and `body`); the HTTP
status lands in `terminationStatus`, just as a pipe's exit status
does. `file://` URLs work in every mode — they bypass the network
stack entirely.

### The bridge

`FS.open(_ mode:)` turns a node into a stream, and honors the ENOENT
rule — a chain into a not-yet-existing file opens fine with a creating
mode:

```swift
let out = try FS.temp["results"]["run1.log"].open(.write)
```

## `Sys` — the process

A caseless enum: a pure namespace, nothing to instantiate.

| | |
|---|---|
| `Sys.argv` | `[String]`, `argv[0]` included — `sys.argv`, `@ARGV` |
| `Sys.env` | dictionary-style environment — `%ENV` (below) |
| `Sys.exit(_:)` | terminate with a status — `sys.exit` |
| `Sys.executable` | the running binary, as an `FS` node — `sys.executable` |
| `Sys.pid` / `ppid` | process ids — `$$` |
| `Sys.uid` / `euid` / `gid` / `egid` | user/group ids — `$<`, `$>`, `$(`, `$)` |
| `Sys.user` | effective user's login name |
| `Sys.platform` | `"darwin"` / `"linux"` — `sys.platform` |
| `Sys.byteOrder` | `"little"` / `"big"` — `sys.byteorder` |
| `Sys.hostname` / `osVersion` / `cpuCount` | the machine |
| `Sys.uname` | `uname(2)` decoded: sysname/nodename/release/version/machine |
| `Sys.stdin` / `stdout` / `stderr` | the standard `IO` streams — `sys.stdin` & co. |

The environment reads and writes like the dictionary it morally is,
and iterates sorted:

```swift
Sys.env["PATH"]                  // String?
Sys.env["DEBUG"] = "1"           // setenv — visible to children
Sys.env.unset("DEBUG")           // unsetenv (assigning nil works too)
for (key, value) in Sys.env { print("\(key)=\(value)") }
```

## Redirection operators

Shell redirection with csh/zsh noclobber manners. The right-hand side
is the target file name; the left-hand side — an `FS` node or an `IO`
stream — pours its contents in. Each returns the fresh `FS` node of
the target:

| operator | mirror | action | target exists | target missing |
|---|---|---|---|---|
| `>`  | `<`   | write  | **throws** `EEXIST` | creates |
| `>!` | `!<`  | write  | clobbers | creates |
| `>>` | `<<`  | append | appends | **throws** `ENOENT` |
| `>>!`| `!<<` | append | appends | creates |

```swift
try FS("draft.txt") > "final.txt"    // safe by default
try FS("draft.txt") >! "final.txt"   // the bang means you mean it
try node >> "app.log"                // append to an existing log
try stream >>! "app.log"             // ...creating it if needed
try FS("src") !< "dst"               // mirrors, bang mirrored too
```

`String` deliberately does *not* conform to `RedirectionSource`:
`"a" > "b"` is a plain Swift string comparison and stays one — wrap
the source in `FS(...)` to say you mean a file. One parsing note:
the `>>`-family binds tighter than `+`, so build target paths into a
variable rather than concatenating inline.

## `IO.HTTPS` / `IO.HTTP` — the web

HTTP-with-TLS is the one protocol in this kit that carries encryption
and certificate verification, so it gets a first-class type instead of
hiding behind `IO.open` — namespaced under `IO`, where protocols live
as siblings. `IO.HTTPS`'s promise: **it is TLS-only**. Whatever scheme
the spec carries is replaced by the type's own, and there is
deliberately no "skip verification" switch — URLSession's full
certificate-chain validation always applies.

`IO.HTTP` is the plaintext sibling — deprecated on the public
internet, still the lingua franca of intranets. Same builders, same
verbs, same `Response`; the *only* way to speak plaintext is to type
`IO.HTTP`, never a spec string (`IO.HTTPS("http://x")` upgrades, and
`IO.HTTP("https://x")` stays plaintext — the type always wins).

```swift
IO.HTTPS("example.com")                          // https://example.com
IO.HTTPS("api.github.com")["users"]["dankogai"]  // chain paths, FS-style
IO.HTTPS("api.example")
    .query("q", "swift")                      // ?q=swift
    .header("Authorization", "Bearer \(t)")   // carried by every verb
    .timeout(30)
```

Values are immutable and chainable; every builder returns a new
`HTTPS`. Then the REST verbs — `get()`, `head()`, `post(_:)`,
`put(_:)`, `patch(_:)`, `delete()`, or the general
`request(_:body:headers:)` — perform the call synchronously and
return a `Response`:

```swift
let r = try IO.HTTPS("api.github.com")["users"]["dankogai"].get()
r.status          // 200
r.ok              // true for 2xx
r.headers         // response headers
r.bodyString      // the body (also `body: Data`)
```

Verbs return the `Response` even for non-2xx — REST scripts want to
branch on status. When a bad status should throw, chain `validate()`:

```swift
try IO.HTTPS("api.example")["missing"].get().validate()   // throws IO.HTTPError(404)
```

Transport failures (DNS, TLS, refused connections) always throw. And
`open()` bridges to the other pillars — GET the body as an `IO`
stream.

## Usage

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/dankogai/swift-swiftysys", from: "0.1.0")
]
```

and add `"SwiftySys"` to your target dependencies.

### In the REPL

```sh
swift run --repl
```

```swift
import SwiftySys
FS.home[".zshrc"].string
try IO.qx("uptime")
```

## Roadmap

- `IO` sockets (`IO.connect(...)`, and opening `FS`'s `.socket`/`.fifo` nodes)
- Buffered line iteration (`for line in io.lines`)
- `copy` / `move`, glob

## Caveats

- **macOS and Linux only.** Not iOS — but then, neither is scripting.
- **The `FS` case is a snapshot.** It is decided by one `lstat(2)` at
  construction; if the disk changes afterward the value is stale
  (a `.file` that has been deleted still says `.file`). Perl and Python
  live with the same TOCTOU reality. Use `refreshed()` when it matters;
  the stat accessors (`size`, `mtime`, …) always re-stat anyway.

## License

MIT. See [LICENSE](LICENSE).
