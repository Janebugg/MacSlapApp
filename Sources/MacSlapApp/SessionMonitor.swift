import AppKit

/// Reports the user getting into their macOS session: logging in (the app is
/// started as a login item), unlocking the screen, or switching back to this
/// account with fast user switching.
@MainActor
final class SessionMonitor {
    /// The app counts as started by a login if the Dock, which starts with
    /// the session, is younger than this.
    private static let loginGrace: TimeInterval = 180
    /// Unlock and session-active can both fire for one return to the account.
    private static let debounceInterval: TimeInterval = 5
    /// Sounds load off the main thread at launch; give them time before playing.
    private static let launchDelay: TimeInterval = 3

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastLogin: Date = .distantPast

    var onLogin: ((String) -> Void)?

    func start() {
        guard tokens.isEmpty else { return }

        if let age = Self.sessionAge(), age < Self.loginGrace {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
                self?.fire("login")
            }
        }

        let distributed = DistributedNotificationCenter.default()
        tokens.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire("unlock") }
        }))

        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append((workspace, workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire("user switch") }
        }))
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func fire(_ reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastLogin) >= Self.debounceInterval else { return }
        lastLogin = now
        log("Session: \(reason)")
        onLogin?(reason)
    }

    /// Seconds since this user's Dock started, read from the kernel because
    /// launchd-started processes carry no NSRunningApplication.launchDate.
    private static func sessionAge() -> TimeInterval? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, dock.processIdentifier]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let started = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        return Date().timeIntervalSince(started)
    }
}
