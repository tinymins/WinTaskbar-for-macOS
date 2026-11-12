import Foundation
import SwiftUI

// Parsing happens only when editing finishes, so partial input never changes preferences.
enum NotificationNumericText {
    static func double(_ input: String, bounds: ClosedRange<Double>) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = NSRegularExpression.escapedPattern(for: formatter.decimalSeparator ?? ".")
        let pattern = "^[+-]?(?:\\p{Nd}+(?:\(separator)\\p{Nd}*)?|\(separator)\\p{Nd}+)$"
        guard text.range(of: pattern, options: .regularExpression) != nil,
              let parsed = formatter.number(from: text)?.doubleValue, parsed.isFinite else { return nil }
        return min(bounds.upperBound, max(bounds.lowerBound, parsed))
    }

    static func integer(_ input: String, bounds: ClosedRange<Int>) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "^[+-]?\\p{Nd}+$", options: .regularExpression) != nil,
              let parsed = try? Int(text, format: .number.grouping(.never)) else { return nil }
        return min(bounds.upperBound, max(bounds.lowerBound, parsed))
    }
}

// Buttons do not necessarily resign a macOS text field. Each editor flushes its own
// active field before previewing or copying settings; cancelling never flushes it.
@MainActor
final class NotificationNumericEditingScope: ObservableObject {
    private var active: (id: UUID, commit: () -> Void)?

    func register(_ id: UUID, commit: @escaping () -> Void) {
        active = (id, commit)
    }

    func unregister(_ id: UUID) {
        if active?.id == id { active = nil }
    }

    func commitPending() { active?.commit() }
}

private struct NotificationNumericEditingScopeKey: EnvironmentKey {
    static let defaultValue: NotificationNumericEditingScope? = nil
}

extension EnvironmentValues {
    var notificationNumericEditingScope: NotificationNumericEditingScope? {
        get { self[NotificationNumericEditingScopeKey.self] }
        set { self[NotificationNumericEditingScopeKey.self] = newValue }
    }
}

struct NotificationNumericField<Value: Equatable>: View {
    let title: LocalizedStringKey
    @Binding var value: Value
    let format: (Value) -> String
    let parse: (String) -> Value?
    let sliderEditing: Bool
    @State private var text = ""
    @State private var editingID = UUID()
    @FocusState private var focused: Bool
    @Environment(\.notificationNumericEditingScope) private var editingScope

    init(_ title: LocalizedStringKey, value: Binding<Value>,
         format: @escaping (Value) -> String, parse: @escaping (String) -> Value?,
         sliderEditing: Bool = false) {
        self.title = title
        _value = value
        self.format = format
        self.parse = parse
        self.sliderEditing = sliderEditing
    }

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = format(value) }
            .onChange(of: value) { newValue in
                if !focused { text = format(newValue) }
            }
            .onChange(of: sliderEditing) { editing in
                if editing {
                    focused = false
                    text = format(value)
                }
            }
            .onChange(of: focused) { editing in
                if editing {
                    editingScope?.register(editingID, commit: commit)
                } else {
                    commit()
                    editingScope?.unregister(editingID)
                }
            }
            .onSubmit { commit() }
            .onDisappear { editingScope?.unregister(editingID) }
    }

    private func commit() {
        if let parsed = parse(text), parsed != value { value = parsed }
        text = format(value)
    }
}

// The draft belongs to the row, including its readout. Only a completed gesture is persisted.
struct NotificationNumericSetting<Value: Equatable>: View {
    let title: LocalizedStringKey
    @Binding var value: Value
    let sliderRange: ClosedRange<Double>
    let step: Double?
    let showsField: Bool
    let toSlider: (Value) -> Double
    let fromSlider: (Double) -> Value
    let format: (Value) -> String
    let parse: (String) -> Value?
    let readout: ((Value) -> String)?
    @State private var draft: Value
    @State private var dragging = false

    init(_ title: LocalizedStringKey, value: Binding<Value>, sliderRange: ClosedRange<Double>,
         step: Double? = nil, showsField: Bool = true,
         toSlider: @escaping (Value) -> Double, fromSlider: @escaping (Double) -> Value,
         format: @escaping (Value) -> String, parse: @escaping (String) -> Value?,
         readout: ((Value) -> String)? = nil) {
        self.title = title
        _value = value
        self.sliderRange = sliderRange
        self.step = step
        self.showsField = showsField
        self.toSlider = toSlider
        self.fromSlider = fromSlider
        self.format = format
        self.parse = parse
        self.readout = readout
        _draft = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        HStack {
            Text(title).frame(width: 180, alignment: .leading)
            Group {
                if let step {
                    Slider(value: sliderBinding, in: sliderRange, step: step, onEditingChanged: editingChanged)
                } else {
                    Slider(value: sliderBinding, in: sliderRange, onEditingChanged: editingChanged)
                }
            }
            .accessibilityLabel(title)
            if showsField {
                NotificationNumericField(title, value: fieldBinding, format: format, parse: parse,
                                         sliderEditing: dragging)
                    .frame(width: 68)
            }
            if let readout {
                Text(readout(draft)).monospacedDigit().frame(width: 58, alignment: .trailing)
            }
        }
        .onChange(of: value) { newValue in
            if !dragging { draft = newValue }
        }
    }

    private var fieldBinding: Binding<Value> {
        Binding(get: { draft }, set: { newValue in
            guard !dragging else { return }
            draft = newValue
            if value != newValue { value = newValue }
        })
    }

    private var sliderBinding: Binding<Double> {
        Binding(get: { min(sliderRange.upperBound, max(sliderRange.lowerBound, toSlider(draft))) },
                set: { draft = fromSlider($0) })
    }

    private func editingChanged(_ editing: Bool) {
        dragging = editing
        if !editing, value != draft { value = draft }
    }
}
