import SwiftUI
import AppKit
import PauselyCore

struct JoinSessionView: View {
    @State private var code = ""
    @State private var hasError = false
    @FocusState private var isFocused: Bool
    var onJoin: ((String) -> Bool)?
    var onCancel: (() -> Void)?

    private var schedule: SessionSchedule? {
        SessionCode.decode(code, now: Date().timeIntervalSince1970)
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Join Collaborative Session")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("Paste or enter a session code.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Session code")
                    .font(.system(size: 13, weight: .medium))
                TextField("6 or 11 characters", text: $code)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .accessibilityLabel("Session code")
                    .onChange(of: code) { _ in hasError = false }
                    .onSubmit(join)
                if let schedule {
                    Text("Work \(DurationValue.label(schedule.work)) · Break \(DurationValue.label(schedule.rest))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text(hasError ? "Check the code and try again." : "Preset and custom schedules are supported.")
                        .font(.system(size: 13))
                        .foregroundStyle(hasError ? Color.red : Color.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button("Join", action: join)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 420)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .onAppear { isFocused = true }
    }

    private func join() {
        guard schedule != nil, onJoin?(code) == true else { hasError = true; return }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
