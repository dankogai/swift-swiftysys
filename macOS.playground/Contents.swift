//: # SwiftySys
//: System programming made Swifty — as easy as Perl, Python, or Ruby,
//: yet swifty. Two types: `FS` for filesystem *nodes*, `IO` for *streams*.
//:
//: (Open the package folder in Xcode and run this playground;
//:  it builds the SwiftySys scheme automatically.)
import Foundation
import SwiftySys

//: ## FS — what is it?
//: One `lstat(2)` at construction decides the case.
FS("/etc/hosts")                        // FS.file(/etc/hosts)
FS("/etc")                              // FS.directory(/etc)
FS("/tmp")                              // FS.symlink(/tmp) — macOS!
FS("/tmp").resolved()                   // FS.directory(/private/tmp)
FS("/dev/null")                         // FS.characterDevice(/dev/null)
FS("/nonexistent")                      // FS.error(ENOENT, /nonexistent)

//: ## Chain without fear
//: No `!`, no `?`, no `try` — errors propagate monadically,
//: SwiftyJSON style.
FS("/nonexistent")["deep"]["deeper"]    // still just ENOENT, full path
FS("/etc/hosts")["oops"]                // ENOTDIR — frozen at /etc/hosts
FS("/") / "etc" / "hosts"               // the / operator does the same

//: ## Terminal accessors — pick your style
let hosts = FS("/etc/hosts")
hosts.string?.prefix(80)                // String?  — nil on error
hosts.stringValue.count                 // String   — "" on error
hosts.data?.count                       // Data?
FS("/nonexistent").string               // nil — no crash
FS("/nonexistent").stringValue          // "" — the YOLO crowd
FS("/nonexistent").error                // Errno? tells you why

//: ## stat(2) without tears
hosts.size
hosts.mtime
hosts.permissions
hosts.uid
hosts.inode

//: ## Directories behave like [String: FS]
let etc = FS("/etc")
etc.count
etc.keys.prefix(10)
//: ...so `filter` / `map` / `contains` come for free —
//: this is where Swift starts to beat Perl:
let bigOnes = etc
    .filter { $0.node.isFile && $0.node.sizeValue > 5000 }
    .map(\.name)
bigOnes
for (name, node) in FS("/var/log") where node.isFile {
    name
}

//: ## Writing — a scratch area in temp
let demo = try FS.temp["swiftysys-demo"].mkdir()
try demo["hello.txt"].write("hello, world\n")
demo["hello.txt"].string
try demo["hello.txt"].append("goodbye\n")
demo["hello.txt"].stringValue

//: ## Assignment sugar — the Perl-tie dream
//: `=` writes, `+=` appends, `= FS(...)` copies.
//: No `var` needed: the disk mutates, not the enum.
demo["motd.txt"] = "hello, world\n"
demo["motd.txt"].string
demo["motd.txt"] += "and goodbye\n"
demo["motd.txt"].stringValue
demo["hosts.copy"] = FS("/etc/hosts")        // copy a node
demo["hosts.copy"].size
let typed: String? = demo["motd.txt"]        // typed getter reads back
typed
//: Deletion is deliberately NOT sugared — rm should look like rm:
try demo["motd.txt"].remove()
demo["motd.txt"].exists
//: Failures are silent (setters cannot throw) but never invisible:
FS("/etc/hosts")["nope"] = "denied"          // ENOTDIR — a no-op
FS("/etc/hosts")["nope"].error               // ...and here is why

//: A chain into a not-yet-existing path knows where to create:
try demo["a"]["b"]["c"].mkdir(withIntermediates: true)
demo["a"]["b"]["c"].isDirectory

//: ## The classic POSIX calls, house style
try demo["hello.txt"].chmod(0o600)
demo["hello.txt"].permissions
//: chmod also speaks chmod(1)'s symbolic modes:
try demo["hello.txt"].chmod("u+x")       // 0o700
try demo["hello.txt"].chmod("a=rwX")     // 0o777 — u had x, so X applies
try demo["hello.txt"].chmod("u=rw,go=r") // back to 0o644
demo["hello.txt"].permissions
//: ...or one Bool at a time — bare names mean the user (owner) bit:
demo["hello.txt"].executable = true      // chmod u+x, as an assignment
demo["hello.txt"].executable
demo["hello.txt"].otherWritable          // false
demo["hello.txt"].groupReadable          // true
demo["hello.txt"].executable = false     // and back
try demo["hello.txt"].chown(user: Sys.user)  // to ourselves — allowed
let renamed = try demo["hello.txt"].rename(to: demo.pathString + "/renamed.txt")
let mirror = try renamed.link(to: demo.pathString + "/mirror.txt")
mirror.inode == renamed.inode            // hard links share the inode
try renamed.rename(to: demo.pathString + "/hello.txt")  // put it back
try demo["hello.txt"].utime(mtime: Date(timeIntervalSince1970: 0))
demo["hello.txt"].mtime                  // the epoch!
try demo["hello.txt"].touch()            // freshened
try demo["stamp"].touch()                // created
try demo["pipe"].mkfifo()                // FS.fifo(...)
try mirror.remove()

//: Symlinks:
let link = try demo["shortcut"].symlink(to: "hello.txt")
link.linkTarget
link.string                              // reading follows the link
link.size                                // ...but stat is lstat: the link's own size
link.resolved()

//: ## IO — streams: files, pipes, processes
//: Perl's 2-arg open, as sugar for literals:
let out = try IO.open("> \(demo.pathString)/numbers.txt")
try out.write("3\n1\n2\n")
try out.close()

let sorted = try IO.open("sort \(demo.pathString)/numbers.txt |")
try sorted.readString()                  // "1\n2\n3\n"
try sorted.close()

//: Perl's backticks:
try IO.qx("uname -a")
try IO.qx("date")

//: ## The safer list form — argv straight through, NO shell
//: (Perl's `open $fh, "-|", @cmd` — nothing to inject.)
let ls = try IO.readPipe(from: ["ls", "-la", demo.pathString])
try ls.readString()
try ls.close()

//: Shell metacharacters arrive verbatim:
let evil = "$(whoami); rm -rf / | `date`"
let safe = try IO.readPipe(from: ["echo", evil])
try safe.readString()                    // the literal string, untouched

//: Write to a process — sort into a file, no redirection needed:
let sink = try IO.writePipe(to: ["sort", "-o", demo.pathString + "/sorted.txt"])
try sink.write("banana\napple\ncherry\n")
try sink.close()                         // waits; returns exit status
demo["sorted.txt"].stringValue

//: Exit status, like Perl's `$?`:
let failing = try IO.readPipe(from: ["false"])
try failing.readAll()
try failing.close()                      // 1

//: ## Redirection operators — noclobber manners
//: `>` writes (throws if target exists), `>!` clobbers,
//: `>>` appends (target must exist), `>>!` creates too.
//: Mirrors `<` `!<` `<<` `!<<` do the same, bang mirrored.
//: Sources are FS nodes or IO streams — never bare Strings:
//: `"a" > "b"` stays a plain Swift string comparison.
let dst = demo.pathString + "/hello.copy"
try demo["hello.txt"] > dst              // copy, safely
FS(dst).string
//: Running it twice would throw EEXIST — hence the bang:
try demo["hello.txt"] >! dst             // clobber, deliberately
try demo["hello.txt"] >>! (demo.pathString + "/all.txt")  // node → append
try IO.readPipe(from: ["date"]) >>! (demo.pathString + "/all.txt")  // stream → append
FS(demo.pathString + "/all.txt").string

//: ## open3 — stdout and stderr, separately (IPC::Open3)
let p3 = try IO.open3("echo output; echo diagnostics >&2")
try p3.stdout.readString()               // "output\n"
try p3.stderr.readString()               // "diagnostics\n"
p3.close()
//: `capture` feeds stdin and slurps both sides with poll(2) —
//: no pipe-buffer deadlocks, ever:
let r = try IO.open3(["tr", "a-z", "A-Z"]).capture(stdin: "shout this\n")
r.stdoutString                           // "SHOUT THIS\n"
r.stderrString                           // ""
r.status                                 // 0

//: ## URLs — Ruby's open-uri (needs network, hence the try?)
let page = try? IO.open("https://www.example.com").readString()
page?.prefix(80)
//: Writing POSTs on close: `IO.open("| https://api.example")`

//: ## HTTPS — the secure web, first-class
//: TLS-only by construction: schemes are forced to https, and CA
//: verification always applies. Paths chain like FS, verbs are REST:
IO.HTTPS("api.github.com")["users"]["dankogai"]   // builds the URL
IO.HTTPS("example.com").query("q", "swift sys")   // ?q=swift%20sys
IO.HTTPS("http://example.com")                    // upgraded to https!
let resp = try? IO.HTTPS("www.example.com").timeout(15).get()
resp?.status                                   // 200
resp?.ok
resp?.bodyString.prefix(80)
//: Non-2xx doesn't throw (branch on .status); validate() when it should:
//: `try IO.HTTPS("api.example")["missing"].get().validate()` → HTTPError(404)
//: And IO.HTTP is the plaintext sibling for intranets — same builders,
//: same verbs; the scheme is chosen by the TYPE, never a spec string:
IO.HTTP("intranet.local:8080")["api"]["v1"]       // http://intranet.local:8080/api/v1
IO.HTTP("https://example.com").url                // stays http — the type wins

//: ## Sys — the process view (Python's sys, Perl's core variables)
Sys.argv                                 // @ARGV, argv[0] included
Sys.executable                           // the running binary, as an FS node
Sys.pid                                  // $$
Sys.user                                 // who am I
Sys.platform                             // "darwin"
Sys.uname.machine                        // "arm64"?
Sys.hostname
Sys.cpuCount
Sys.byteOrder
//: The environment is a dictionary — %ENV:
Sys.env["HOME"]
Sys.env["SWIFTYSYS"] = "playground"      // setenv — children see it
try IO.qx("printf '%s' \"$SWIFTYSYS\"")     // proof
Sys.env.unset("SWIFTYSYS")

//: ## FS meets IO
let log = try demo["run.log"].open(.append)   // node → stream
try log.write("it just works\n")
try log.close()
demo["run.log"].string

//: ## Clean up
try demo.remove(recursively: true)
FS.temp["swiftysys-demo"].exists         // false — and that's the tour!
