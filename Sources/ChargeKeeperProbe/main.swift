// Charge Keeper, phase 1 proof: can this Mac's own built-in charge limit (macOS "MCL", in the private PowerUI
// framework) be set from a tool, verified, and always put back? Original code. No SMC key is ever written.
//
//   probe                  read-only: is the limit supported, on or off, which limit, available steps, battery state
//   test [pct] [--try89]   set the limit (default 90), verify, restore; kill -9 test; survives-restart check.
//                          --try89 also asks for 89 (not one of the offered steps) to see if macOS accepts it
//   restore                put the limit back to off / 100
//   selftest               pure logic checks (no hardware)
import Foundation
import IOKit

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - PowerUI client (private framework, reached by method address because it has no public header)

struct State: Equatable {
    var enabled: Bool; var limit: Int
    // A switched-off limit has no meaningful level, so only "off" is compared then.
    func matches(_ o: State?) -> Bool { o != nil && enabled == o!.enabled && (!enabled || limit == o!.limit) }
}
typealias Err = UnsafeMutablePointer<Unmanaged<AnyObject>?>?

final class MCL {
    private let obj: AnyObject
    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"),
              let raw = class_createInstance(cls, 0) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        let f = unsafeBitCast(class_getMethodImplementation(cls, Selector(("initWithClientName:"))), to: Init.self)
        guard let o = f(raw as AnyObject, Selector(("initWithClientName:")), "com.johnhesch.keeper") else { return nil }
        obj = o.takeUnretainedValue()
    }
    private func imp<T>(_ s: String, _ t: T.Type) -> T {
        unsafeBitCast(class_getMethodImplementation(object_getClass(obj), Selector((s))), to: t)
    }
    var lastError = ""
    private func err(_ e: Unmanaged<AnyObject>?) { lastError = e.map { "\($0.takeUnretainedValue())" } ?? "" }

    var supported: Bool { imp("isMCLSupported", (@convention(c) (AnyObject, Selector) -> Bool).self)(obj, Selector(("isMCLSupported"))) }
    func enabled() -> Bool? {
        var e: Unmanaged<AnyObject>? = nil
        let v = imp("isMCLCurrentlyEnabled:", (@convention(c) (AnyObject, Selector, Err) -> UInt).self)(obj, Selector(("isMCLCurrentlyEnabled:")), &e)
        err(e)
        return e == nil ? v != 0 : nil
    }
    func limit() -> Int? {
        var e: Unmanaged<AnyObject>? = nil
        let v = imp("getMCLLimitWithError:", (@convention(c) (AnyObject, Selector, Err) -> UInt8).self)(obj, Selector(("getMCLLimitWithError:")), &e)
        err(e)
        return e == nil ? Int(v) : nil
    }
    func available() -> [Int] {
        var e: Unmanaged<AnyObject>? = nil
        let v = imp("availableChargeLimitsWithError:", (@convention(c) (AnyObject, Selector, Err) -> Unmanaged<AnyObject>?).self)(obj, Selector(("availableChargeLimitsWithError:")), &e)
        return ((v?.takeUnretainedValue() as? [NSNumber]) ?? []).map { $0.intValue }
    }
    func state() -> State? {
        guard let e = enabled(), let l = limit() else { return nil }
        return State(enabled: e, limit: l)
    }
    @discardableResult func setLimit(_ pct: Int) -> Bool {
        var e: Unmanaged<AnyObject>? = nil
        let ok = imp("setMCLLimit:error:", (@convention(c) (AnyObject, Selector, UInt8, Err) -> Bool).self)(obj, Selector(("setMCLLimit:error:")), UInt8(pct), &e)
        err(e)
        return ok
    }
    @discardableResult func enable() -> Bool { toggle("enableMCL:") }
    @discardableResult func disable() -> Bool { toggle("disableMCL:") }
    private func toggle(_ s: String) -> Bool {
        var e: Unmanaged<AnyObject>? = nil
        let ok = imp(s, (@convention(c) (AnyObject, Selector, Err) -> Bool).self)(obj, Selector((s)), &e)
        err(e)
        return ok
    }
}

// Puts the setting back to `orig` and checks by reading, retrying. Safe to call any number of times.
func restore(_ m: MCL, _ orig: State, tries: Int = 5) -> Bool {
    for _ in 0..<tries {
        if let s = m.state(), s.matches(orig) { return true }
        m.setLimit(orig.limit)
        if orig.enabled { m.enable() } else { m.disable() }
        if let s = m.state(), s.matches(orig) { return true }
        sleep(1)
    }
    return false
}

// Pure decision: only touch a Mac whose limit is supported, currently off, and where the target is an offered step.
func canEngage(supported: Bool, state: State?, available: [Int], target: Int) -> Bool {
    supported && state?.enabled == false && available.contains(target)
}

// MARK: - battery state

struct Battery {
    var charging: Bool?, external: Bool?, current: Int?, max: Int?, amps: Int?, reason: Int?
    var text: String {
        func s<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "?" }
        return "charging=\(s(charging)) plugged_in=\(s(external)) level=\(s(current))/\(s(max)) amperage_mA=\(s(amps)) not_charging_reason=\(s(reason))"
    }
}
func battery() -> Battery {
    let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return Battery() }
    defer { IOObjectRelease(svc) }
    func p(_ k: String) -> NSNumber? { IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber }
    return Battery(charging: p("IsCharging")?.boolValue, external: p("ExternalConnected")?.boolValue,
                   current: p("CurrentCapacity")?.intValue, max: p("MaxCapacity")?.intValue, amps: p("Amperage").map { Int($0.int64Value) },
                   reason: ((IORegistryEntryCreateCFProperty(svc, "ChargerData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any])?["NotChargingReason"] as? NSNumber)?.intValue)
}
func pmsetLine() -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g", "batt"]; p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?"
}

func waitFor(_ seconds: Int, _ cond: () -> Bool) -> Bool {
    for _ in 0..<(seconds / 2 + 1) {
        if cond() { return true }
        sleep(2)
    }
    return cond()
}

// MARK: - the hold: set the limit with a watchdog that puts it back no matter how this process ends

func selfPath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}

// Starts a process in its own session, so a Ctrl-C or a kill aimed at this tool does not reach it.
func spawnDetached(_ args: [String]) -> pid_t? {
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    var defaults = sigset_t()
    sigfillset(&defaults)  // the parent ignores SIGINT/SIGTERM; the watchdog must not inherit that
    posix_spawnattr_setsigdefault(&attr, &defaults)
    posix_spawnattr_setflags(&attr, Int16(0x0400 | 0x04))  // POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF
    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
    var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    cargs.append(nil)
    var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)
    defer { cargs.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, args[0], &fa, &attr, cargs, envp)
    return rc == 0 ? pid : nil
}

final class Hold {
    let m: MCL, orig: State
    private var watchdog: pid_t = 0
    private let lock = NSLock()
    private var active = false
    init(_ m: MCL, _ orig: State) { self.m = m; self.orig = orig }

    func engage(target: Int, deadline: Int) -> Bool {
        let wdArgs = [selfPath(), "watchdog", String(getpid()), String(deadline), orig.enabled ? "1" : "0", String(orig.limit)]
        guard let pid = spawnDetached(wdArgs) else { return false }
        watchdog = pid
        usleep(700_000)
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == 0 else { return false }  // already exited: no watchdog, so no change
        // Held for the whole change, so a signal's release() waits and then restores everything.
        lock.lock(); defer { lock.unlock() }
        active = true
        guard m.setLimit(target) else { releaseLocked(); return false }
        if m.enabled() != true { m.enable() }  // setting the level may already switch it on
        guard m.state() == State(enabled: true, limit: target) else { releaseLocked(); return false }
        return true
    }
    // Safe to call from anywhere, any number of times.
    func release() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return releaseLocked()
    }
    @discardableResult private func releaseLocked() -> Bool {
        guard active else { return true }
        let ok = restore(m, orig)
        if ok { active = false; if watchdog > 0 { kill(watchdog, SIGTERM); watchdog = 0 } }  // watchdog only exits; the parent already restored
        return ok
    }
}

var currentHold: Hold? = nil
var signalSources: [DispatchSourceSignal] = []

// Every ending we can catch (normal exit, Ctrl-C, terminate, hangup) restores the setting first.
func installExitSafety() {
    atexit { _ = currentHold?.release() }
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
        src.setEventHandler {
            let ok = currentHold?.release() ?? true
            print(ok ? "signal \(sig): limit restored" : "signal \(sig): RESTORE FAILED, run restore")
            exit(130)
        }
        src.resume()
        signalSources.append(src)
    }
}

// MARK: - commands

func describe(_ m: MCL) -> State? {
    let st = m.state()
    print("mcl: supported=\(m.supported) enabled=\(st.map { "\($0.enabled)" } ?? "?") limit=\(st.map { "\($0.limit)" } ?? "?") available=\(m.available()) user=\(geteuid())")
    print("battery: \(battery().text) | \(pmsetLine())")
    return st
}

func runTest(target: Int, try89: Bool) -> Int32 {
    guard let m = MCL() else { print("PowerUI client could not be created. Nothing was changed."); return 1 }
    let st = describe(m)
    let avail = m.available()
    guard canEngage(supported: m.supported, state: st, available: avail, target: target), let orig = st else {
        print("RESULT: limit unsupported, already on, or \(target) is not an offered step. Nothing was changed.")
        return 1
    }
    let b0 = battery()
    guard b0.external == true, b0.charging == true else {
        print("RESULT: Mac is not plugged in and charging right now (\(b0.text)), so a stop cannot be shown. Nothing was changed.")
        return 1
    }
    installExitSafety()
    let hold = Hold(m, orig)
    currentHold = hold
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
        if !ok { failures += 1 }
    }

    // A: set, observe, restore, observe
    guard hold.engage(target: target, deadline: 900) else {
        print("FAIL could not set the limit (\(m.lastError)); restored: \(restore(m, orig))"); return 1
    }
    check("A0 limit set and read back", m.state() == State(enabled: true, limit: target), "state=\(String(describing: m.state()))")
    let stopped = waitFor(90) { battery().charging == false }
    check("A1 charging stopped after the limit was set", stopped, "\(battery().text) | \(pmsetLine())")
    // C: a fresh tool process sees the same setting (the macOS service keeps it, not this tool)
    let probeOut = run([selfPath(), "probe"])
    check("C1 a new tool process sees the limit (survives a tool restart)", probeOut.contains("enabled=true limit=\(target)"))
    if try89 {
        let ok = m.setLimit(89)
        print("INFO try89: setMCLLimit(89) returned \(ok) error='\(m.lastError)' readback=\(String(describing: m.state()))")
    }
    check("A3 restore verified by reading", hold.release(), "state=\(String(describing: m.state()))")
    check("A4 charging resumed after restore", waitFor(120) { battery().charging == true }, "\(battery().text) | \(pmsetLine())")
    currentHold = nil

    // B: the tool is killed hard while the limit is set
    let child = Process()
    child.executableURL = URL(fileURLWithPath: selfPath())
    child.arguments = ["hold", String(target), "120"]
    let pipe = Pipe()
    child.standardOutput = pipe
    do { try child.run() } catch { check("B0 start hold process", false); return 1 }
    let line = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
    check("B1 second process is holding the limit", line.contains("held") && m.state() == State(enabled: true, limit: target))
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    let restored = waitFor(10) { m.state()?.matches(orig) == true }
    check("B2 after kill -9 the watchdog put the limit back", restored)
    if !restored { print("emergency restore: \(restore(m, orig))") }
    check("B3 charging resumed after kill -9", waitFor(120) { battery().charging == true }, "\(battery().text) | \(pmsetLine())")

    let finalOK = m.state()?.matches(orig) == true
    print("FINAL: setting at original (\(orig)): \(finalOK); battery \(battery().text)")
    print("RESULT: \(failures == 0 && finalOK ? "PROVEN" : "NOT PROVEN") (sleep/wake: not tested)")
    return failures == 0 && finalOK ? 0 : 1
}

func run(_ argv: [String]) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = Array(argv.dropFirst()); p.standardOutput = pipe
    try? p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return out
}

func selftest() -> Int32 {
    var bad = 0
    func expect(_ c: Bool, _ n: String) { if !c { print("FAIL \(n)"); bad += 1 } }
    let off = State(enabled: false, limit: 100)
    expect(canEngage(supported: true, state: off, available: [80, 90, 100], target: 90), "off + offered step is allowed")
    expect(!canEngage(supported: true, state: off, available: [80, 90, 100], target: 89), "unoffered step refused")
    expect(!canEngage(supported: true, state: State(enabled: true, limit: 90), available: [90], target: 90), "already on refused")
    expect(!canEngage(supported: false, state: off, available: [90], target: 90), "unsupported refused")
    expect(!canEngage(supported: true, state: nil, available: [90], target: 90), "unreadable state refused")
    expect(State(enabled: false, limit: 90).matches(off) && !State(enabled: true, limit: 100).matches(off), "off compares only the switch")
    expect(State(enabled: true, limit: 90).matches(State(enabled: true, limit: 90)) && !State(enabled: true, limit: 85).matches(State(enabled: true, limit: 90)), "on compares the level")
    print(bad == 0 ? "selftest ok" : "selftest FAILED")
    return bad == 0 ? 0 : 1
}

// MARK: - entry

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "probe" {
case "probe":
    guard let m = MCL() else { print("PowerUI client could not be created"); exit(1) }
    _ = describe(m)
case "test":
    let pct = args.dropFirst(2).compactMap { Int($0) }.first ?? 90
    exit(runTest(target: pct, try89: args.contains("--try89")))
case "restore":
    guard let m = MCL() else { print("PowerUI client could not be created"); exit(2) }
    let ok = restore(m, State(enabled: false, limit: 100))
    print("restore: \(ok) state=\(String(describing: m.state()))")
    exit(ok ? 0 : 1)
case "hold":  // internal: used by the kill test. args = target, seconds
    guard args.count > 2, let target = Int(args[2]), let m = MCL(), let orig = m.state(),
          canEngage(supported: m.supported, state: orig, available: m.available(), target: target) else { print("refused"); exit(1) }
    installExitSafety()
    let hold = Hold(m, orig)
    currentHold = hold
    guard hold.engage(target: target, deadline: 150) else { print("failed"); exit(1) }
    print("held")
    sleep(UInt32(args.count > 3 ? Int(args[3]) ?? 30 : 30))
    exit(hold.release() ? 0 : 1)
case "watchdog":  // internal: args = parent pid, deadline seconds, original enabled (0/1), original limit
    guard args.count == 6, let parent = pid_t(args[2]), let deadline = Int(args[3]), let lim = Int(args[5]), let m = MCL() else { exit(2) }
    let orig = State(enabled: args[4] == "1", limit: lim)
    let end = Date().addingTimeInterval(TimeInterval(deadline))
    // getppid changes when the parent dies, even if the parent is a zombie
    while getppid() == parent && Date() < end { usleep(300_000) }
    exit(restore(m, orig, tries: 20) ? 0 : 1)
case "selftest":
    exit(selftest())
default:
    print("usage: probe | test [pct] [--try89] | restore | selftest")
    exit(2)
}
