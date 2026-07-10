import SwiftUI
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
            
            Text("Share this 6-character code with others to let them join your synced session.")
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            
            ZStack {
                // Visual boxes
                HStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { index in
                        OTPBox(
                            character: character(at: index),
                            isActive: false
                        )
                    }
                }
            }
            .padding(.vertical, 8)
            
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
    
    private func character(at index: Int) -> String {
        guard index < code.count else { return "" }
        let charIndex = code.index(code.startIndex, offsetBy: index)
        return String(code[charIndex])
    }
}
