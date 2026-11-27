//
//  AppSettings.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  UserDefaults keys and simple preference types. Preferences hold no note content.
//

import Foundation

/// Version info shown in the About panel and on the lock screen.
enum AppInfo {
    /// CFBundleShortVersionString must stay numeric ("0.12.2"); the channel prefix is added for display.
    static let channel = ""          // stable release: no channel prefix
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    /// e.g. "v1.1.5"
    static var versionLabel: String { "\(channel)v\(shortVersion)" }
}

enum SettingsKeys {
    static let autoLockMinutes = "autoLockMinutes"      // 0 = manually only
    static let autoLockLastMinutes = "autoLockLastMinutes" // restored when leaving "manually only"
    static let lockOnSleep = "lockOnSleep"
    static let editorMode = "editorMode"                // EditorMode raw value
    static let editorFontSize = "editorFontSize"        // points
    static let sortField = "sortField"                  // NoteSortField raw value
    static let sortAscending = "sortAscending"
    static let trashAutoEmptyDays = "trashAutoEmptyDays" // 0 = never
    static let autoBackupEnabled = "autoBackupEnabled"
    static let autoBackupFolder = "autoBackupFolder"    // path
    static let lastAutoBackup = "lastAutoBackup"        // Date
    static let showMenuBarItem = "showMenuBarItem"
    static let quickNoteHotKey = "quickNoteHotKey"      // QuickNoteHotKey raw value
    static let browserFollowsSelection = "browserFollowsSelection"
    static let browserIconSize = "browserIconSize"      // points
    static let updateAutoCheck = "updateAutoCheck"      // daily update check (off by default)
    static let updateLastCheck = "updateLastCheck"      // Date
    static let updateSkippedBuild = "updateSkippedBuild" // build number the user skipped
    static let updateIncludeBeta = "updateIncludeBeta"  // also offer beta builds
    /// Redirect saved from a signed manifest, per channel ("stable" / "beta").
    static func updateFeedURL(_ channel: String) -> String { "updateFeedURL." + channel }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoLockMinutes: 5,
            autoLockLastMinutes: 5,
            lockOnSleep: true,
            editorMode: EditorMode.split.rawValue,
            editorFontSize: 14.0,
            sortField: NoteSortField.edited.rawValue,
            sortAscending: false,
            trashAutoEmptyDays: 30,
            autoBackupEnabled: false,
            showMenuBarItem: false,
            quickNoteHotKey: QuickNoteHotKey.controlOptionN.rawValue,
            browserFollowsSelection: true,
            browserIconSize: 72.0,
            updateAutoCheck: false,
        ])
    }
}

/// How the note editor area is laid out.
enum EditorMode: String, CaseIterable, Identifiable {
    case edit
    case split
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: return "Editor Only"
        case .split: return "Editor and Preview"
        case .preview: return "Preview Only"
        }
    }

    var systemImage: String {
        switch self {
        case .edit: return "doc.plaintext"
        case .split: return "rectangle.split.2x1"
        case .preview: return "eye"
        }
    }

    static var current: EditorMode {
        get { EditorMode(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.editorMode) ?? "") ?? .split }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.editorMode) }
    }
}

/// How the note list is ordered (pinned notes always come first).
enum NoteSortField: String, CaseIterable, Identifiable {
    case edited
    case created
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edited: return "Date Edited"
        case .created: return "Date Created"
        case .title: return "Title"
        }
    }

    static var current: NoteSortField {
        NoteSortField(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.sortField) ?? "") ?? .edited
    }
}

/// Global shortcut that opens the menu-bar quick note.
enum QuickNoteHotKey: String, CaseIterable, Identifiable {
    case off
    case controlOptionN
    case controlOptionSpace
    case controlOptionCommandN

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "None"
        case .controlOptionN: return "⌃⌥N"
        case .controlOptionSpace: return "⌃⌥Space"
        case .controlOptionCommandN: return "⌃⌥⌘N"
        }
    }

    static var current: QuickNoteHotKey {
        QuickNoteHotKey(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.quickNoteHotKey) ?? "") ?? .controlOptionN
    }
}
