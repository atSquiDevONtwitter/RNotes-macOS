//
//  MenuBarController.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Optional menu-bar quick note: a status-bar icon (and a global shortcut, ⌃⌥N by default)
//  opens a small popover to jot something down. Notes are saved to a "Quick Notes" folder.
//  The draft lives only in memory and is wiped when RNotes locks.
//

import AppKit
import SwiftUI
import Carbon.HIToolbox

final class MenuBarController: NSObject, ObservableObject, NSPopoverDelegate {
    /// The quick note being typed (plain text in memory only; cleared on lock).
    @Published var draft = ""
    /// Bumped every time the popover opens, so the view can move focus.
    @Published private(set) var openCount = 0

    private let vault: Vault
    private let store: NoteStore
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hotKey: GlobalHotKey?
    private var hotKeySetting: QuickNoteHotKey = .off
    /// When the popover last closed — a click on the icon that closed it shouldn't reopen it.
    private var lastClose = Date.distantPast
    /// Main RNotes windows (registered by RootView), for "Open RNotes".
    static let mainWindows = NSHashTable<NSWindow>.weakObjects()

    init(vault: Vault, store: NoteStore) {
        self.vault = vault
        self.store = store
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = QuickNoteView(controller: self)
            .environmentObject(vault)
            .environmentObject(store)
        popover.contentViewController = NSHostingController(rootView: root)
        vault.onWillLock { [weak self] in
            self?.draft = ""
            self?.popover.performClose(nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc private func defaultsChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.applySettings() }
    }

    /// Shows or hides the menu-bar item and (re)registers the shortcut to match Settings.
    func applySettings() {
        let show = UserDefaults.standard.bool(forKey: SettingsKeys.showMenuBarItem)
        if show && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: "square.and.pencil",
                                    accessibilityDescription: "RNotes Quick Note")
                image?.isTemplate = true
                button.image = image
                button.target = self
                button.action = #selector(statusItemClicked(_:))
                button.toolTip = "RNotes Quick Note"
            }
            statusItem = item
        } else if !show, let item = statusItem {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }

        let wanted: QuickNoteHotKey = show ? QuickNoteHotKey.current : .off
        if wanted != hotKeySetting {
            hotKey = nil                                  // unregisters the old one
            hotKeySetting = wanted
            if let spec = Self.keySpec(for: wanted) {
                hotKey = GlobalHotKey(keyCode: spec.code, modifiers: spec.modifiers) { [weak self] in
                    self?.togglePopover()
                }
                if hotKey == nil {
                    NSLog("RNotes: the quick-note shortcut %@ is used by another app", wanted.title)
                }
            }
        }
    }

    private static func keySpec(for key: QuickNoteHotKey) -> (code: UInt32, modifiers: UInt32)? {
        switch key {
        case .off: return nil
        case .controlOptionN:
            return (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey))
        case .controlOptionSpace:
            return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .controlOptionCommandN:
            return (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey | cmdKey))
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if !popover.isShown && Date().timeIntervalSince(lastClose) < 0.25 { return }
        togglePopover()
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        openCount += 1
    }

    func close() {
        popover.performClose(nil)
    }

    /// Saves the draft into the Quick Notes folder.
    func save() -> Bool {
        guard store.addQuickNote(draft) else { return false }
        draft = ""
        return true
    }

    /// Brings the main window forward, opening a new one if all were closed.
    func openMainWindow() {
        close()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = Self.mainWindows.allObjects.first(where: { $0.isVisible || $0.isMiniaturized }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // Re-opening our own (running) app asks SwiftUI for a fresh window.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - Global shortcut (Carbon hot key — works without Accessibility permission)

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, context, &handlerRef)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x524E_5445), id: 1)   // 'RNTE'
        let registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let h = handlerRef { RemoveEventHandler(h) }
            handlerRef = nil
            return nil
        }
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let h = handlerRef { RemoveEventHandler(h) }
    }
}

// MARK: - Registering main windows

/// Put in the main window's background so the menu bar can bring that window forward.
struct MainWindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = RegistrarView()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class RegistrarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window = window { MenuBarController.mainWindows.add(window) }
        }
    }
}
