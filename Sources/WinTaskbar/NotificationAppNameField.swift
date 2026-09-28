import AppKit
import SwiftUI

struct NotificationAppNameField: NSViewRepresentable {
    @Binding var text: String
    let names: [String]

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox()
        field.isEditable = true
        field.completes = true
        field.hasVerticalScroller = true
        field.numberOfVisibleItems = 10
        field.usesDataSource = true
        field.dataSource = context.coordinator
        field.placeholderString = NSLocalizedString("App name contains", comment: "Notification rule application name")
        field.setAccessibilityLabel(field.placeholderString)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSComboBox, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        if coordinator.names != names {
            coordinator.names = names
            field.reloadData()
        }
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate, NSComboBoxDataSource {
        var text: Binding<String>
        var names: [String] = []
        var isUpdating = false

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard !isUpdating, let field = notification.object as? NSComboBox else { return }
            text.wrappedValue = field.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let field = notification.object as? NSComboBox,
                  names.indices.contains(field.indexOfSelectedItem) else { return }
            let name = names[field.indexOfSelectedItem]
            field.stringValue = name
            text.wrappedValue = name
        }

        func numberOfItems(in comboBox: NSComboBox) -> Int { names.count }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            names.indices.contains(index) ? names[index] : nil
        }

        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            names.firstIndex { $0.localizedCaseInsensitiveCompare(string) == .orderedSame } ?? NSNotFound
        }

        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            guard !string.isEmpty else { return nil }
            return names.first { $0.range(of: string, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
