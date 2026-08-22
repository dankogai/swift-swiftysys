//: # SwiftySys
//: System programming made Swifty — as easy as Perl, Python, or Ruby,
//: yet swifty. Two types: `FS` for filesystem *nodes*, `IO` for *streams*.
//:
//: (Open the package folder in Xcode and run this playground;
//:  it builds the SwiftySys scheme automatically.)
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
try qx("uname -a")
try qx("date")

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

//: ## FS meets IO
let log = try demo["run.log"].open(.append)   // node → stream
try log.write("it just works\n")
try log.close()
demo["run.log"].string

//: ## Clean up
try demo.remove(recursively: true)
FS.temp["swiftysys-demo"].exists         // false — and that's the tour!
