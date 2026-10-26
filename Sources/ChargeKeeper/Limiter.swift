// Takes the Mac's charge limit, and always gives it back: on quit, on a catchable signal, via a watchdog when
// we are killed hard, and via a start-up check after a crash. This replaces the "safe helper" of the old plan:
// the limit needs no special permission, so nothing separate has to run.
import Foundation

enum Applied: Equatable { case ok, foreign, unsupported, failed(String) }

let markerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Charge Keeper/engaged")

final class Limiter {
    private let m: MCL
    private let lock = NSLock()
    private var orig: LimitState?  // the setting before we touched it; non-nil exactly while we own the limit
    private var watchdog: pid_t = 0
    private var closed = false  // set by the final release at exit, so a late timer tick cannot take the limit again
    init(_ m: MCL) { self.m = m }

    // A note left by an earlier run means that run died with the limit on: put it back. No note = not ours, never touched.
    func clearLeftover() {
        guard let text = try? String(contentsOf: markerURL) else { return }
        let lim = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 100
        if restore(m, LimitState(enabled: false, limit: lim)) { try? FileManager.default.removeItem(at: markerURL) }
    }

    // Holds the limit at `target`. Cheap when it already holds.
    func apply(_ target: Int) -> Applied {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return .failed("Charge Keeper is closing.") }
        guard m.supported else { return .unsupported }
        guard let cur = m.state() else { return .failed("Could not read the Mac's charge limit.") }
        if orig == nil {
            guard !cur.enabled else { return .foreign }  // the Mac's own limit (or another app's) is on: do not fight it
            guard startWatchdog(cur) else { return .failed("Could not start the safety watchdog, so nothing was changed.") }
            orig = cur
        } else if cur == LimitState(enabled: true, limit: target) {
            return .ok
        }
        guard m.setLimit(target) else { return fail("macOS refused the limit \(target)%") }
        if m.enabled() != true { m.enable() }  // setting the level may already switch it on
        guard m.state() == LimitState(enabled: true, limit: target) else { return fail("macOS did not keep the limit \(target)%") }
        return .ok
    }

    // Safe to call from anywhere, any number of times. True when nothing of ours is left on.
    @discardableResult func release(final: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if final { closed = true }
        return releaseLocked()
    }

    private func fail(_ why: String) -> Applied {
        let back = releaseLocked()
        return .failed(back ? why : "\(why), and putting charging back failed: run Charge Keeper with --restore")
    }

    private func releaseLocked() -> Bool {
        guard let o = orig else { return true }
        guard restore(m, o) else { return false }  // stays armed: the watchdog and the next start-up check still cover it
        orig = nil
        try? FileManager.default.removeItem(at: markerURL)
        if watchdog > 0 { kill(watchdog, SIGTERM); waitpid(watchdog, nil, 0); watchdog = 0 }  // it only exits; we already restored
        return true
    }

    // The watchdog says "r" once its own PowerUI client works; no "r" (it died or hung) means no change is made.
    private func startWatchdog(_ o: LimitState) -> Bool {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return false }
        let pid = spawnDetached([selfPath(), "--watchdog", String(getpid()), String(o.limit)], stdoutFd: fds[1])
        close(fds[1])
        defer { close(fds[0]) }
        guard let pid else { return false }
        var pfd = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
        var byte: UInt8 = 0
        guard poll(&pfd, 1, 5000) == 1, read(fds[0], &byte, 1) == 1, byte == UInt8(ascii: "r") else {
            kill(pid, SIGKILL); waitpid(pid, nil, 0); return false
        }
        // The note goes down before the first change, so a crash at any later point is found at the next start.
        do {
            try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try String(o.limit).write(to: markerURL, atomically: true, encoding: .utf8)
        } catch { kill(pid, SIGKILL); waitpid(pid, nil, 0); return false }
        watchdog = pid
        return true
    }
}

// MARK: - every ending we can catch restores first

var activeLimiter: Limiter? = nil
var signalSources: [DispatchSourceSignal] = []

func installExitSafety(_ l: Limiter) {
    activeLimiter = l
    atexit { _ = activeLimiter?.release(final: true) }  // covers the Quit button too: terminate() ends in exit()
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
        src.setEventHandler { _ = activeLimiter?.release(final: true); exit(0) }
        src.resume()
        signalSources.append(src)
    }
}

// The second copy of this program, started by apply(): waits for its parent to die, then puts the limit back.
func runWatchdog(_ args: [String]) -> Never {
    guard args.count == 4, let parent = pid_t(args[2]), let lim = Int(args[3]), let m = MCL() else { exit(2) }
    write(1, "r", 1)
    while getppid() == parent { usleep(300_000) }  // getppid changes when the parent dies, even as a zombie
    let ok = restore(m, LimitState(enabled: false, limit: lim), tries: 20)
    if ok { try? FileManager.default.removeItem(at: markerURL) }  // put back: the note must not outlive it, or the next start would undo a limit John sets later
    exit(ok ? 0 : 1)
}
