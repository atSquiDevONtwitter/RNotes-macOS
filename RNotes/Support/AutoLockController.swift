//
//  AutoLockController.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Locks the vault after a period of inactivity in RNotes, and whenever the
//  Mac sleeps, the screen sleeps/locks, or the user switches accounts.
//

import AppKit

/// Shared limits and labels for the auto-lock time.
enum AutoLock {
    static let minMinutes = 1
    static let maxMinutes = 1440                    // 24 hours
    static let presets = [1, 5, 15, 30, 60, 120, 240]

    static func clamp(_ m: Int) -> Int { min(max(m, minMinutes), maxMinutes) }

    static func title(_ m: Int) -> String {
        if m % 60 == 0 { let h = m / 60; return h == 1 ? "1 Hour" : "\(h) Hours" }
        return m == 1 ? "1 Minute" : "\(m) Minutes"
    }
}

final class AutoLockController {
    private let vault: Vault
    private var lastActivity = Date()
    private var eventMonitor: Any?
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var started = false
    private var lastSeenMinutes = UserDefaults.standard.integer(forKey: SettingsKeys.autoLockMinutes)
    private var defaultsObserver: NSObjectProtocol?

    init(vault: Vault) {
        self.vault = vault
    }

    /// Call once the app is running (e.g. from the first window's onAppear).
    func start() {
        guard !started else { return }
        started = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }

        // Changing the time limit restarts the idle clock, so lowering it (or leaving
        // "manually only") never locks straight away because of an old idle time.
        // Only a change to this one setting counts; other preferences changing doesn't.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let now = UserDefaults.standard.integer(forKey: SettingsKeys.autoLockMinutes)
            if now != self.lastSeenMinutes {
                self.lastSeenMinutes = now
                self.noteActivity()
            }
        }

        let ws = NSWorkspace.shared.notificationCenter
        let sleepNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in sleepNames {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.lockForSleep()
            })
        }
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.lockForSleep()
        })
    }

    /// Reset the idle clock (e.g. right after unlocking).
    func noteActivity() {
        lastActivity = Date()
    }

    private func checkIdle() {
        guard vault.state == .unlocked else { lastActivity = Date(); return }
        let minutes = UserDefaults.standard.integer(forKey: SettingsKeys.autoLockMinutes)
        guard minutes > 0 else { return }               // 0 = manually only
        if Date().timeIntervalSince(lastActivity) >= TimeInterval(minutes * 60) {
            vault.lock()
        }
    }

    private func lockForSleep() {
        if UserDefaults.standard.bool(forKey: SettingsKeys.lockOnSleep) {
            vault.lock()
        }
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        timer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
}
