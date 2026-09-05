import SwiftUI
import PauselyCore
import AppKit

struct HostSessionView: View {
    let code: String
    var onDone: (() -> Void)?
    
    @State private var isVisible = false
    @State private var isHoveringCopy = false
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Session Started")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("Share this code to join the same work and break schedule.")
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            
            Text(SessionCode.display(code))
                .font(.system(size: code.count == 6 ? 36 : 28, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.textBackgroundColor).opacity(0.8))
                .cornerRadius(8)
                .accessibilityLabel("Session code")
                .accessibilityValue(code)

            if code.count == 11 {
                Text("Custom schedules need the latest Pausely on both devices.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(code, forType: .string)
                    onDone?()
                }) {
                    Text("Copy Code & Close")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 150, height: 36)
                        .background(isHoveringCopy ? Color.accentColor.opacity(0.8) : Color.accentColor)
                        .cornerRadius(8)
                        .scaleEffect(isHoveringCopy ? 1.02 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHoveringCopy)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    isHoveringCopy = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 420)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.95)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isVisible)
        .onAppear {
            isVisible = true
        }
    }
    
}
