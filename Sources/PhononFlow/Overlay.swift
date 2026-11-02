import Cocoa
import SwiftUI

final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case hidden, listening, handsFree, transcribing, message(String) }
    @Published var phase: Phase = .hidden
    /// Newest level last. Displayed mirrored so the newest sits in the center and spreads outward.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 8)

    var mirrored: [CGFloat] { levels + levels.reversed().dropFirst() }

    private var envelope: CGFloat = 0
    private var tickCount = 0
    /// Raw history the displayed bars ease toward (newest last).
    private var targets: [CGFloat] = Array(repeating: 0, count: 8)

    /// Called 60×/s with the latest voice level. Smoothed in three stages so it
    /// still follows syllables but glides instead of jittering:
    /// 1) envelope with a soft attack and slower release,
    /// 2) history shifts ~20×/s,
    /// 3) every bar eases toward its target each frame.
    func tick(rms: Float) {
        let target = CGFloat(min(1, pow(Double(rms) * 28, 0.6)))   // exaggerated gain
        let coef: CGFloat = target > envelope ? 0.45 : 0.12
        envelope += (target - envelope) * coef
        tickCount += 1
        if tickCount % 3 == 0 {
            targets.removeFirst()
            targets.append(envelope)
        } else {
            targets[targets.count - 1] = max(targets[targets.count - 1], envelope)
        }
        var next = levels
        for i in next.indices { next[i] += (targets[i] - next[i]) * 0.28 }
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: levels.count)
        targets = levels
        envelope = 0
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    private var visible: Bool { model.phase != .hidden }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(height: 35)
            .background(
                Capsule().fill(Color.black.opacity(0.9))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            )
            .scaleEffect(visible ? 1 : 0.5, anchor: .bottom)
            .opacity(visible ? 1 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: model.phase)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .listening, .hidden:
            bars
        case .handsFree:
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                bars
            }
        case .transcribing:
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<model.mirrored.count, id: \.self) { i in
                        let d = Double(abs(i - model.levels.count + 1))
                        let h = 4 + 7 * (0.5 + 0.5 * sin(t * 7 - d * 0.7))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 1.75, height: h)
                    }
                }
            }
        case .message(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
    }

    private var bars: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(model.mirrored.enumerated()), id: \.offset) { i, level in
                // Taper toward the edges so the center reads loudest.
                let d = CGFloat(abs(i - model.levels.count + 1)) / CGFloat(model.levels.count - 1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(width: 1.75, height: 3 + level * 24 * (1 - 0.4 * d))
            }
        }
    }
}

/// Borderless, click-through floating panel at the bottom of the active screen.
final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private var meterTimer: Timer?
    /// Supplies the loudest level since the last call (from the recorder).
    var levelSource: (() -> Float)?

    func startMeter() {
        meterTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, let src = self.levelSource else { return }
            self.model.tick(rms: src())
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    func show(_ phase: OverlayModel.Phase) {
        hideWork?.cancel()
        if !panel.isVisible {
            position()
            model.resetLevels()
            panel.orderFrontRegardless()
        }
        model.phase = phase
    }

    /// Slight "vibrate": trackpad haptic (felt if a finger is on a Force Touch trackpad).
    func buzz() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func hide() {
        model.phase = .hidden
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.phase == .hidden else { return }
            self.panel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func flash(_ text: String) {
        show(.message(text))
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 14))
    }
}
