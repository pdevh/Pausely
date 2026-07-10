import SwiftUI
import AppKit

struct JoinSessionView: View {
    @State private var code: String = ""
    @FocusState private var isFocused: Bool
    
    var onJoin: ((String) -> Void)?
    var onCancel: (() -> Void)?
    @State private var isVisible = false
    @State private var isHoveringCancel = false
    @State private var isHoveringJoin = false
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Join Collaborative Session")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("Enter the 6-character session code")
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundColor(.secondary)
            
            ZStack {
                // Hidden TextField
                TextField("", text: $code)
                    .focused($isFocused)
                    .onChange(of: code) { newValue in
                        let upper = newValue.uppercased().filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) }
                        if upper.count > 6 {
                            code = String(upper.prefix(6))
                        } else if newValue != upper {
                            code = upper
                        }
                    }
                    .opacity(0.0)
                    .frame(width: 0, height: 0)
                
                // Visual boxes
                HStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { index in
                        OTPBox(
                            character: character(at: index),
                            isActive: isFocused && (index == code.count || (code.count == 6 && index == 5))
                        )
                        .onTapGesture {
                            isFocused = true
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            
            HStack(spacing: 16) {
                Button(action: {
                    onCancel?()
                }) {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 100, height: 36)
                        .background(isHoveringCancel ? Color.gray.opacity(0.1) : Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .scaleEffect(isHoveringCancel ? 1.02 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHoveringCancel)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    isHoveringCancel = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                
                Button(action: {
                    if code.count == 6 {
                        onJoin?(code)
                    }
                }) {
                    Text("Join")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 100, height: 36)
                        .background(
                            code.count == 6 
                                ? (isHoveringJoin ? Color.accentColor.opacity(0.8) : Color.accentColor) 
                                : Color.gray.opacity(0.5)
                        )
                        .cornerRadius(8)
                        .scaleEffect(isHoveringJoin && code.count == 6 ? 1.02 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHoveringJoin)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(code.count != 6)
                .animation(.easeInOut, value: code.count == 6)
                .onHover { hovering in
                    isHoveringJoin = hovering
                    if hovering && code.count == 6 {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }
    
    private func character(at index: Int) -> String {
        guard index < code.count else { return "" }
        let charIndex = code.index(code.startIndex, offsetBy: index)
        return String(code[charIndex])
    }
}

struct OTPBox: View {
    let character: String
    let isActive: Bool
    
    @State private var isPopping = false
    
    var body: some View {
        Text(character)
            .font(.system(size: 32, weight: .bold, design: .monospaced))
            .foregroundColor(.primary)
            .frame(width: 48, height: 60)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isActive ? 2.5 : 1)
                    .shadow(color: isActive ? Color.accentColor.opacity(0.4) : .clear, radius: 4, x: 0, y: 0)
            )
            .animation(.easeInOut(duration: 0.15), value: isActive)
            .scaleEffect(isPopping ? 1.15 : 1.0)
            .onChange(of: character) { newValue in
                if !newValue.isEmpty {
                    isPopping = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            isPopping = false
                        }
                    }
                }
            }
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
