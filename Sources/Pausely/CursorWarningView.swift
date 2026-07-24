import SwiftUI

class CursorWarningViewModel: ObservableObject {
    @Published var timeRemaining: Int = 10
    @Published var isVisible: Bool = false
}

struct CursorWarningView: View {
    @ObservedObject var viewModel: CursorWarningViewModel
    @State private var rotation: Double = 0
    @State private var hourglassRotation: Double = 0

    // Pausely's app icon uses blue and yellow. Keeping the warning in the
    // same palette makes it feel like part of the product instead of a red
    // system-error alert.
    private let brandBlue = Color(red: 63 / 255, green: 155 / 255, blue: 1)
    private let brandYellow = Color(red: 1, green: 214 / 255, blue: 0)
    
    var body: some View {
        HStack(spacing: 10) {
            // Animated, glowing orb using the Pausely brand palette.
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [brandBlue, brandYellow, brandBlue]),
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
                            gradient: Gradient(colors: [brandBlue.opacity(0.7), brandYellow.opacity(0.65)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        // Soft drop shadow in colors
        .shadow(color: brandBlue.opacity(0.22), radius: 10, x: 0, y: 6)
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
