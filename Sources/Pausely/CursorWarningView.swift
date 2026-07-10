import SwiftUI

class CursorWarningViewModel: ObservableObject {
    @Published var timeRemaining: Int = 10
    @Published var isVisible: Bool = false
}

struct CursorWarningView: View {
    @ObservedObject var viewModel: CursorWarningViewModel
    @State private var rotation: Double = 0
    @State private var hourglassRotation: Double = 0
    
    var body: some View {
        HStack(spacing: 10) {
            // Animated, glowing orb with a vivid sunset gradient
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [Color.pink, Color.orange, Color.yellow, Color.pink]),
                            center: .center,
                            startAngle: .degrees(rotation),
                            endAngle: .degrees(rotation + 360)
                        )
                    )
                    .frame(width: 24, height: 24)
                    .blur(radius: 4)
                
                Image(systemName: "hourglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(hourglassRotation))
            }
            
            Text("Break in \(viewModel.timeRemaining)s")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.default, value: viewModel.timeRemaining)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background(
            ZStack {
                VisualEffectBackground()
                    .clipShape(Capsule())
                
                Capsule()
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.pink.opacity(0.6), Color.orange.opacity(0.6)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        // Soft drop shadow in colors
        .shadow(color: Color.pink.opacity(0.2), radius: 10, x: 0, y: 6)
        .fixedSize() // Prevents the capsule from stretching to fill the NSWindow
        .opacity(viewModel.isVisible ? 1.0 : 0.0)
        .scaleEffect(viewModel.isVisible ? 1.0 : 0.85)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: viewModel.isVisible)
        .padding(20) // padding to make room for shadow in the NSWindow
        .onAppear {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                hourglassRotation = 180
            }
        }
    }
}
