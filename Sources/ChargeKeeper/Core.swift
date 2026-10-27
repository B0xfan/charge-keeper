// Charge Keeper core: the Mac's own built-in charge limit (macOS "MCL", in the private PowerUI framework),
// proven in Phase 1 to work as a normal user. Original code. No charging-chip key is ever written.
import Foundation
import IOKit

// MARK: - PowerUI client (private framework, reached by method address because it has no public header)

struct LimitState: Equatable {
    var enabled: Bool; var limit: Int
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
    var supported: Bool { imp("isMCLSupported", (@convention(c) (AnyObject, Selector) -> Bool).self)(obj, Selector(("isMCLSupported"))) }
    func enabled() -> Bool? {
        var e: Unmanaged<AnyObject>? = nil
        let v = imp("isMCLCurrentlyEnabled:", (@convention(c) (AnyObject, Selector, Err) -> UInt8).self)(obj, Selector(("isMCLCurrentlyEnabled:")), &e)  // low byte only: a 1-byte BOOL leaves the upper bits undefined
        return e == nil ? v != 0 : nil
    }
    func limit() -> Int? {
        var e: Unmanaged<AnyObject>? = nil
        let v = imp("getMCLLimitWithError:", (@convention(c) (AnyObject, Selector, Err) -> UInt8).self)(obj, Selector(("getMCLLimitWithError:")), &e)
        return e == nil ? Int(v) : nil
    }
    func state() -> LimitState? {
        guard let e = enabled(), let l = limit() else { return nil }
        return LimitState(enabled: e, limit: l)
    }
    @discardableResult func setLimit(_ pct: Int) -> Bool {
        guard (1...100).contains(pct), let level = UInt8(exactly: pct) else { return false }
        var e: Unmanaged<AnyObject>? = nil
        let ok = imp("setMCLLimit:error:", (@convention(c) (AnyObject, Selector, UInt8, Err) -> Bool).self)(obj, Selector(("setMCLLimit:error:")), level, &e)
        return ok
    }
    @discardableResult func enable() -> Bool { toggle("enableMCL:") }
    @discardableResult func disable() -> Bool { toggle("disableMCL:") }
    private func toggle(_ s: String) -> Bool {
        var e: Unmanaged<AnyObject>? = nil
        let ok = imp(s, (@convention(c) (AnyObject, Selector, Err) -> Bool).self)(obj, Selector((s)), &e)
        return ok
    }
}

// Puts the setting back to `orig` and checks by reading, retrying. Safe to call any number of times.
func restore(_ m: MCL, _ orig: LimitState, tries: Int = 5) -> Bool {
    for _ in 0..<tries {
        // Done only if the level is back too: a half-applied change can leave "off" with 89 stored, which a switch-only check would accept.
        if m.state() == orig { return true }
        m.setLimit(orig.limit)
        if orig.enabled { m.enable() } else { m.disable() }
        if m.state() == orig { return true }
        sleep(1)
    }
    return false
}

// MARK: - battery state

struct Battery {
    var charging: Bool?, external: Bool?, current: Int?
}
func battery() -> Battery {
    let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return Battery() }
    defer { IOObjectRelease(svc) }
    func p(_ k: String) -> NSNumber? { IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber }
    return Battery(charging: p("IsCharging")?.boolValue, external: p("ExternalConnected")?.boolValue, current: p("CurrentCapacity")?.intValue)  // CurrentCapacity is a percent on Apple silicon (MaxCapacity reads 100)
}

// MARK: - a process that outlives us

func selfPath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}

// Starts a process in its own session, so a Ctrl-C or a kill aimed at us does not reach it.
func spawnDetached(_ args: [String], stdoutFd: Int32) -> pid_t? {
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    var defaults = sigset_t()
    sigfillset(&defaults)  // we ignore SIGINT/SIGTERM; the child must not inherit that
    posix_spawnattr_setsigdefault(&attr, &defaults)
    var none = sigset_t()
    sigemptyset(&none)
    posix_spawnattr_setsigmask(&attr, &none)  // the work thread has SIGTERM blocked, and a child inherits that mask
    // CLOEXEC_DEFAULT: only the descriptors below reach the child. An inherited helper connection would stay open after the app dies.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&fa, stdoutFd, 1)
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
