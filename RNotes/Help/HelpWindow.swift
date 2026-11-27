//
//  HelpWindow.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Help ▸ RNotes Help (⌘?): a searchable help window. Topics are rendered with the
//  same Markdown preview as notes, and [[links]] between topics work like note links.
//  The help is static text, so it's available even while RNotes is locked.
//

import SwiftUI
import AppKit

// MARK: - Window

final class HelpWindowController: NSObject, NSWindowDelegate {
    static let shared = HelpWindowController()

    private let model = HelpModel()
    private var window: NSWindow?

    /// Shows the help window, optionally at a specific topic.
    func show(topicID: String? = nil) {
        if let id = topicID { model.open(id) }
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "RNotes Help"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 680, height: 420)
        window.contentViewController = NSHostingController(rootView: HelpView(model: model))
        window.setContentSize(NSSize(width: 900, height: 620))
        window.center()
        window.setFrameAutosaveName("RNotesHelpWindow")   // remembers size and position
        return window
    }
}

// MARK: - State

final class HelpModel: ObservableObject {
    @Published private(set) var currentID = HelpContent.welcomeID
    @Published var search = ""
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []

    var current: HelpTopic { HelpContent.topic(id: currentID) ?? HelpContent.welcome }

    func open(_ id: String) {
        guard id != currentID, HelpContent.topic(id: id) != nil else { return }
        backStack.append(currentID)
        forwardStack.removeAll()
        currentID = id
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentID)
        currentID = previous
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentID)
        currentID = next
    }

    /// Topics matching the search (all words must appear), in help order.
    var results: [HelpTopic] {
        let words = search.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return HelpContent.all.filter { topic in
            let text = topic.searchText.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}

// MARK: - Views

struct HelpView: View {
    @ObservedObject var model: HelpModel
    @AppStorage(SettingsKeys.editorFontSize) private var fontSize: Double = 14

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            content
        }
        .frame(minWidth: 680, minHeight: 420)
    }

    // Sidebar: search field, then sections (or search results).

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search Help", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .padding(10)

            List {
                if model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(HelpContent.sections) { group in
                        Section(group.section.rawValue) {
                            ForEach(group.topics) { row($0) }
                        }
                    }
                } else {
                    let results = model.results
                    Section(results.isEmpty ? "No Results" : "Results") {
                        ForEach(results) { row($0) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ topic: HelpTopic) -> some View {
        HelpTopicRow(topic: topic, isSelected: topic.id == model.currentID) {
            model.open(topic.id)
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
    }

    // Content: navigation bar + rendered topic.

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: model.back) { Image(systemName: "chevron.left") }
                    .disabled(model.backStack.isEmpty)
                    .help("Back")
                Button(action: model.forward) { Image(systemName: "chevron.right") }
                    .disabled(model.forwardStack.isEmpty)
                    .help("Forward")
                Button { model.open(HelpContent.welcomeID) } label: { Image(systemName: "house") }
                    .disabled(model.currentID == HelpContent.welcomeID)
                    .help("Help home")
                Text(model.current.title)
                    .font(.headline)
                    .padding(.leading, 8)
                Spacer()
                Text("RNotes \(AppInfo.versionLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            MarkdownPreviewView(markdown: model.current.markdown,
                                fontSize: fontSize,
                                titleKeys: HelpContent.titleKeys,
                                onTagClick: { _ in model.open("tags") },
                                onOpenLink: { target in
                                    if let topic = HelpContent.topic(linkedAs: target) { model.open(topic.id) }
                                })
                // A fresh page per topic, so each one opens scrolled to the top.
                .id(model.currentID)
        }
    }
}

struct HelpTopicRow: View {
    let topic: HelpTopic
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: topic.icon)
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 18)
            Text(topic.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundColor(isSelected ? .white : .primary)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
