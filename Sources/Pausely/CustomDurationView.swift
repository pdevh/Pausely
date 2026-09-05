import SwiftUI
import PauselyCore

struct CustomDurationView: View {
    let title: String
    let explanation: String
    let onSave: (Int) -> Void
    let onCancel: () -> Void
    @State private var draft: DurationDraft
    @FocusState private var isFocused: Bool

    init(title: String, explanation: String, seconds: Int,
         onSave: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.explanation = explanation
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: DurationDraft(seconds: seconds))
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(explanation)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                Text(draft.seconds.map(DurationValue.clock) ?? "–:––")
                    .font(.system(size: 48, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(draft.seconds == nil ? Color.secondary : Color.primary)
                    .accessibilityLabel("Duration preview")
                    .accessibilityValue(draft.seconds.map(DurationValue.label) ?? "Invalid duration")
                Text(draft.seconds.map(DurationValue.label) ?? "Enter a valid duration")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Duration")
                    .font(.system(size: 13, weight: .medium))
                TextField("Seconds or m:ss", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 18, design: .monospaced))
                    .focused($isFocused)
                    .accessibilityLabel("Duration in seconds or clock notation")
                    .onSubmit(save)
                Text("Enter seconds (37), m:ss (2:37), or h:mm:ss.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                adjustment("−1 min", delta: -60, label: "Subtract one minute")
                adjustment("−1 sec", delta: -1, label: "Subtract one second")
                adjustment("+1 sec", delta: 1, label: "Add one second")
                adjustment("+1 min", delta: 60, label: "Add one minute")
            }

            Text(draft.seconds == nil ? "Use a whole-second duration from 1 second to 24 hours." : "From 1 second to 24 hours. Changes apply when saved.")
                .font(.system(size: 12))
                .foregroundStyle(draft.seconds == nil ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.seconds == nil)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 420)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .onAppear { isFocused = true }
    }

    private func adjustment(_ title: String, delta: Int, label: String) -> some View {
        Button(title) { draft.adjust(by: delta) }
            .disabled(!draft.canAdjust(by: delta))
            .accessibilityLabel(label)
            .controlSize(.large)
    }

    private func save() {
        if let seconds = draft.seconds { onSave(seconds) }
    }
}
