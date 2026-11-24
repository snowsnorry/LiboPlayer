import AVFAudio
import Combine
import SwiftUI
import WatchKit

struct LocalVolumeControl: WKInterfaceObjectRepresentable {
    let focused: Bool

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        if focused { control.focus() } else { control.resignFocus() }
    }

    static func dismantleWKInterfaceObject(_ control: WKInterfaceVolumeControl, coordinator: ()) {
        control.resignFocus()
    }
}

struct WatchVolumeOverlay: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var volume: Float?
    @State private var hideTask: Task<Void, Never>?

    // WatchKit owns crown input. Read the actual output level, including changes made on headphones.
    private static let changes = AVAudioSession.sharedInstance()
        .publisher(for: \.outputVolume, options: [.new])
        .receive(on: DispatchQueue.main)

    func body(content: Content) -> some View {
        content
            .blur(radius: volume == nil ? 0 : 3)
            .overlay { if volume != nil { Color.black.opacity(0.14).ignoresSafeArea().allowsHitTesting(false) } }
            .overlay {
                if let volume {
                    WatchVolumeMeter(volume: volume)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: volume != nil)
            .onReceive(Self.changes) { level in
                guard active else { return }
                hideTask?.cancel()
                volume = level
                hideTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(1.1)) } catch { return }
                    volume = nil
                }
            }
            .onChange(of: active) { if !active { clear() } }
            .onDisappear { clear() }
    }

    private func clear() {
        hideTask?.cancel()
        hideTask = nil
        volume = nil
    }
}

private struct WatchVolumeMeter: View {
    let volume: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { screen in
            let left = WKInterfaceDevice.current().crownOrientation == .left
            let height = min(48, screen.size.height * 0.19)
            let track = Capsule()
                .fill(.white.opacity(0.30))
                .frame(width: 5, height: height)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.green).frame(height: height * CGFloat(volume))
                }
                .clipShape(Capsule())
            HStack(spacing: 2) {
                if left { track }
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                      variableValue: Double(volume))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                if !left { track }
            }
            .environment(\.layoutDirection, .leftToRight)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: left ? .leading : .trailing)
            .padding(.top, screen.size.height * 0.27 - height / 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: volume)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue(Text(volume, format: .percent.precision(.fractionLength(0))))
    }
}
