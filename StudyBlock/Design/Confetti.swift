import SwiftUI

/// Full-page celebration: a fresh burst of pieces rains down across the
/// whole page every time `trigger` changes, regardless of where on
/// the board the completed task was.
struct ScreenConfettiOverlay: View {
    let trigger: Int
    @State private var pieces: [ScreenConfettiPiece] = []
    @State private var animate = false
    /// Identifies the burst in flight, so a burst that ends while a newer one
    /// is running doesn't sweep the newer one's pieces off the screen.
    @State private var burst = 0

    /// Longest a burst can last: the last piece to launch, falling slowest.
    private static let maxLifetime = ScreenConfettiPiece.maxDelay + ScreenConfettiPiece.maxDuration

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(pieces) { piece in
                    shape(for: piece)
                        .rotationEffect(.degrees(animate ? piece.endRotation : piece.startRotation))
                        .rotation3DEffect(.degrees(animate ? piece.tumble : 0), axis: piece.axis)
                        .position(x: (animate ? piece.endX : piece.startX) * proxy.size.width,
                                  y: animate ? proxy.size.height + 40 : -30)
                        // Each piece carries its own curve, delay and duration.
                        // This modifier is what makes them independent — the
                        // single shared `withAnimation` this replaced moved all
                        // of them on one clock, which is why the burst looked
                        // like one line sweeping down the screen.
                        .animation(.easeIn(duration: piece.duration).delay(piece.delay), value: animate)
                        // Applied below the animation above, so it governs only
                        // the fade: pieces stay solid on the way down and go out
                        // near the end of their own fall rather than all at once.
                        .opacity(animate ? 0 : 1)
                        .animation(.easeOut(duration: 0.45)
                            .delay(piece.delay + piece.duration - 0.45), value: animate)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: trigger) { _ in fire() }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func shape(for piece: ScreenConfettiPiece) -> some View {
        if piece.isRound {
            Circle()
                .fill(piece.color)
                .frame(width: piece.size, height: piece.size)
        } else {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(piece.color)
                .frame(width: piece.size, height: piece.size * 0.45)
        }
    }

    private func fire() {
        burst += 1
        let current = burst
        pieces = (0..<110).map { _ in ScreenConfettiPiece() }
        animate = false
        // Deferred a tick so SwiftUI sees false → true as a real change, and
        // set plainly rather than inside `withAnimation`, which would override
        // every piece's own animation with one shared curve.
        DispatchQueue.main.async { animate = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxLifetime + 0.3) {
            guard current == burst else { return }
            pieces = []
            animate = false
        }
    }
}

struct ScreenConfettiPiece: Identifiable {
    static let maxDelay = 0.6
    static let maxDuration = 2.1

    let id = UUID()
    let color: Color
    /// Start and end as fractions of the overlay's width: a piece drifts
    /// sideways on the way down instead of dropping down a fixed rail.
    let startX: CGFloat
    let endX: CGFloat
    let size: CGFloat
    /// A quarter of the pieces are round, so the burst isn't 110 identical
    /// rectangles.
    let isRound: Bool
    let startRotation: Double
    let endRotation: Double
    /// Tumble through a random 3D axis — a piece that turns edge-on and
    /// briefly disappears reads as paper rather than a falling brick.
    let tumble: Double
    let axis: (x: CGFloat, y: CGFloat, z: CGFloat)
    /// Staggered launch and an individual fall time. These two are the whole
    /// difference between confetti and a curtain.
    let delay: Double
    let duration: Double

    init() {
        let colors: [Color] = [Theme.accent, Theme.violet, Theme.success, Theme.amber, Theme.danger]
        color = colors.randomElement() ?? Theme.accent
        startX = CGFloat.random(in: 0.02...0.98)
        // Clamped loosely rather than to 0...1: a piece is allowed to drift
        // off the edge, which looks better than one sliding along it.
        endX = min(1.08, max(-0.08, startX + CGFloat.random(in: -0.16...0.16)))
        size = CGFloat.random(in: 5...12)
        isRound = Double.random(in: 0...1) < 0.25
        startRotation = Double.random(in: 0...360)
        endRotation = startRotation + Double.random(in: 240...900)
        tumble = Double.random(in: 360...1440)
        axis = (CGFloat.random(in: 0...1), CGFloat.random(in: 0...1), CGFloat.random(in: 0.2...1))
        delay = Double.random(in: 0...Self.maxDelay)
        duration = Double.random(in: 1.1...Self.maxDuration)
    }
}
