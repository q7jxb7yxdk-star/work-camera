import Combine
import CoreMotion
import SwiftUI

/// Measures the horizon in the fixed portrait preview's coordinates.
@MainActor
final class CameraLevel: ObservableObject {
    enum Reading: Equatable {
        case horizon(angle: Double, pitch: Double)
        case overhead(x: Double, y: Double, isAligned: Bool)
    }

    @Published private(set) var reading: Reading?

    private let motionManager = CMMotionManager()
    private var filteredGravity: (x: Double, y: Double, z: Double)?
    private var generation = 0
    private var isOverhead = false
    private var isOverheadAligned = false

    var isAvailable: Bool { motionManager.isDeviceMotionAvailable }

    func start() {
        guard !motionManager.isDeviceMotionActive else { return }
        guard isAvailable else { return }
        generation += 1
        let currentGeneration = generation
        motionManager.deviceMotionUpdateInterval = 1.0 / 30
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            // Carry only scalar values across the actor boundary.
            let x = motion?.gravity.x
            let y = motion?.gravity.y
            let z = motion?.gravity.z
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                guard !failed, let x, let y, let z else {
                    self.stop()
                    return
                }
                self.update(x: x, y: y, z: z)
            }
        }
    }

    func stop() {
        // Ignore callbacks already queued before stopping or restarting.
        generation += 1
        motionManager.stopDeviceMotionUpdates()
        filteredGravity = nil
        isOverhead = false
        isOverheadAligned = false
        reading = nil
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }

    private func update(x: Double, y: Double, z: Double) {
        guard x.isFinite, y.isFinite, z.isFinite else { return }
        let previous = filteredGravity ?? (x: x, y: y, z: z)
        let filtered = (x: previous.x + 0.2 * (x - previous.x),
                        y: previous.y + 0.2 * (y - previous.y),
                        z: previous.z + 0.2 * (z - previous.z))
        filteredGravity = filtered
        let projection = hypot(filtered.x, filtered.y)
        // Use separate entry/exit thresholds to avoid flickering between modes.
        isOverhead = projection < (isOverhead ? 0.4 : 0.3)
        let next: Reading
        if isOverhead {
            let tolerance = sin((isOverheadAligned ? 1.5 : 1.0) * .pi / 180)
            isOverheadAligned = projection <= tolerance
            // Gravity's screen-plane components measure both axes of flatness.
            next = .overhead(x: (filtered.x * 1_000).rounded() / 1_000,
                             y: (filtered.y * 1_000).rounded() / 1_000,
                             isAligned: isOverheadAligned)
        } else {
            isOverheadAligned = false
            // UIKit/SwiftUI's downward Y axis is opposite Core Motion's Y axis.
            let angle = atan2(-filtered.x, -filtered.y) * 180 / .pi
            // Zero pitch means the phone's screen plane is vertical in any orientation.
            let pitch = atan2(filtered.z, projection) * 180 / .pi
            next = .horizon(angle: (angle * 10).rounded() / 10,
                            pitch: (pitch * 10).rounded() / 10)
        }
        if reading != next { reading = next }
    }

}

struct CameraLevelOverlay: View {
    @Environment(\.displayScale) private var displayScale
    private var lineWidth: CGFloat { 2 / max(displayScale, 1) }

    let gravityAngle: Double
    let pitch: Double
    let referenceAngle: Angle
    let tint: Color

    private var relativeAngle: Double {
        // A horizon is an unoriented line: 0 and 180 degrees are equivalent.
        var angle = (gravityAngle - referenceAngle.degrees)
            .truncatingRemainder(dividingBy: 180)
        if angle > 90 { angle -= 180 }
        if angle < -90 { angle += 180 }
        return angle
    }

    var body: some View {
        let isRollLevel = abs(relativeAngle) <= 1
        let isPitchLevel = abs(pitch) <= 1
        ZStack {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 128, y: 0))
                }
                .stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: lineWidth, dash: [4, 4]))
                .frame(width: 128, height: 0)

                Capsule()
                    .fill(isRollLevel ? tint : .white)
                    .frame(width: 92, height: lineWidth)
                    .rotationEffect(.degrees(isRollLevel ? 0 : relativeAngle))
            }
            .modifier(CameraLevelAutoHide(isAligned: isRollLevel))

            // The vertical pitch line forms a central cross with the roll line.
            Capsule()
                .fill(isPitchLevel ? tint : .white)
                .frame(width: lineWidth, height: 60)
                .offset(y: isPitchLevel ? 0 : CGFloat(min(28, max(-28, -pitch * 1.4))))
                .modifier(CameraLevelAutoHide(isAligned: isPitchLevel))
        }
        .frame(width: 160, height: 160)
        .rotationEffect(referenceAngle)
        .shadow(color: .black.opacity(0.7), radius: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A two-axis target for shooting with the phone nearly parallel to the ground.
struct CameraOverheadLevelOverlay: View {
    @Environment(\.displayScale) private var displayScale
    private var lineWidth: CGFloat { 2 / max(displayScale, 1) }

    let x: Double
    let y: Double
    let isAligned: Bool
    let tint: Color

    var body: some View {
        let color: Color = isAligned ? tint : .white
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 12))
                path.addLine(to: CGPoint(x: 24, y: 12))
                path.move(to: CGPoint(x: 12, y: 0))
                path.addLine(to: CGPoint(x: 12, y: 24))
            }
            .stroke(isAligned ? tint : .white.opacity(0.65), lineWidth: lineWidth)
            .frame(width: 24, height: 24)

            Circle()
                .strokeBorder(color, lineWidth: lineWidth)
                .frame(width: 12, height: 12)
                // Stay in the fixed portrait canvas's coordinates, like the horizon.
                .offset(x: CGFloat(x) * 120, y: CGFloat(-y) * 120)
        }
        .modifier(CameraLevelAutoHide(isAligned: isAligned))
        .frame(width: 128, height: 128)
        .shadow(color: .black.opacity(0.7), radius: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Each axis/target owns a cancellable timer that survives unchanged motion readings.
private struct CameraLevelAutoHide: ViewModifier {
    let isAligned: Bool
    @State private var isHidden = false

    func body(content: Content) -> some View {
        content
            // Reveal immediately on deviation, before the next task starts.
            .opacity(isAligned && isHidden ? 0 : 1)
            .task(id: isAligned) {
                guard !Task.isCancelled else { return }
                isHidden = false
                guard isAligned else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                isHidden = true
            }
    }
}
