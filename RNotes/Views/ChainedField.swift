//
//  ChainedField.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  A native text / password field for multi-field forms. On macOS 12, SwiftUI's
//  SecureField doesn't take part in the Tab key loop inside forms and sheets, so
//  Tab gets stuck. These fields handle Tab / Shift-Tab / Return themselves and
//  move focus through a shared index.
//

import SwiftUI
import AppKit

struct ChainedField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var secure = false
    /// This field's position in the chain (0-based).
    let index: Int
    /// Number of fields in the chain.
    let count: Int
    /// Which field should have keyboard focus.
    @Binding var focus: Int?
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // Take focus when the chain points here (and we don't already have it).
        if focus == index, field.currentEditor() == nil {
            DispatchQueue.main.async {
                guard field.window != nil, field.currentEditor() == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ChainedField

        init(_ parent: ChainedField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let binding = parent.$text          // copy out; no long access to `parent`
            binding.wrappedValue = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            let focus = parent.$focus, index = parent.index
            if focus.wrappedValue != index { focus.wrappedValue = index }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let focus = parent.$focus, index = parent.index, count = max(parent.count, 1)
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                focus.wrappedValue = (index + 1) % count
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                focus.wrappedValue = (index - 1 + count) % count
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let submit = parent.onSubmit
                DispatchQueue.main.async { submit() }
                return true
            default:
                return false
            }
        }
    }
}

/// A right-aligned label next to a field, like a macOS form row.
struct FieldRow<Field: View>: View {
    let label: String
    var labelWidth: CGFloat = 110
    @ViewBuilder let field: () -> Field

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: labelWidth, alignment: .trailing)
            field()
        }
    }
}
