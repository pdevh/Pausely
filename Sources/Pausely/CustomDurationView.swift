import SwiftUI
import PauselyCore

struct CustomDurationView: View {
    let title: String
    let onSave: (Int) -> Void
    let onCancel: () -> Void
    @State private var draft: DurationDraft
    @FocusState private var isFocused: Bool

    init(title: String, seconds: Int,
         onSave: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: DurationDraft(seconds: seconds))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            VStack(spacing: 6) {
                TextField("m:ss", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 42, weight: .medium, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .focused($isFocused)
                    .accessibilityLabel(title)
                    .accessibilityHint("Enter seconds, minutes:seconds, or hours:minutes:seconds. From 1 second to 24 hours.")
                    .help("Enter seconds, m:ss, or h:mm:ss. From 1 second to 24 hours.")
                    .onSubmit(save)
                    .onChange(of: isFocused) { focused in
                        if !focused { draft.normalize() }
                    }
                Text(draft.seconds != nil ? " " : draft.text.isEmpty
                     ? "Enter seconds, m:ss, or h:mm:ss."
                     : "Enter seconds or h:mm:ss, from 1s to 24h.")
                    .font(.system(size: 12))
                    .foregroundStyle(draft.text.isEmpty ? Color.secondary : Color.red)
                    .accessibilityHidden(draft.seconds != nil)
            }

            HStack(spacing: 20) {
                adjustment("Hours", unit: "hour", delta: 3600)
                adjustment("Minutes", unit: "minute", delta: 60)
                adjustment("Seconds", unit: "second", delta: 1)
            }

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
        .padding(28)
        .frame(width: 380)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .onAppear { isFocused = true }
    }

    private func adjustment(_ title: String, unit: String, delta: Int) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Button { draft.adjust(by: -delta) } label: { Image(systemName: "minus").frame(width: 16, height: 16) }
                    .disabled(!draft.canAdjust(by: -delta))
                    .accessibilityLabel("Subtract one \(unit)")
                Button { draft.adjust(by: delta) } label: { Image(systemName: "plus").frame(width: 16, height: 16) }
                    .disabled(!draft.canAdjust(by: delta))
                    .accessibilityLabel("Add one \(unit)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func save() {
        if let seconds = draft.seconds { onSave(seconds) }
    }
}
