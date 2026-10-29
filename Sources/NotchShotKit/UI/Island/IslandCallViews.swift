import AppKit
import SwiftUI

/// Call colours, kept together so the compact wings, the satellite and the
/// expanded card read as one activity: the phone's own green and orange.
enum IslandCallStyle {
    static let green = IslandSystemColor.green
    static let orange = IslandSystemColor.orange
}

/// Time on the call, counted from when the app first held the microphone.
/// Ticks once a second from its own timeline, so only this `Text` re-renders.
struct IslandCallElapsed: View {
    var startedAt: Date
    var font: Font
    var color: Color = IslandCallStyle.green

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            IslandClockText(
                text: IslandClock.formatted(context.date.timeIntervalSince(startedAt)),
                font: font,
                color: color
            )
        }
    }
}

/// A decorative voice meter for the trailing wing. NotchShot cannot read
/// another app's call audio without opening the microphone itself, so this
/// only says "a call is live"; it never pretends to be a level. Reduce Motion
/// holds it still.
///
/// The bars are Core Animation keyframes (see `PlaybackMeterView`), so they
/// run on the render server. The SwiftUI version re-rendered six capsules
/// twelve times a second on the main thread for as long as a call lasted,
/// and stalled whenever the island itself was busy springing.
struct IslandCallWaveform: NSViewRepresentable {
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PlaybackMeterView {
        PlaybackMeterView(style: .call, scale: 1)
    }

    func updateNSView(_ view: PlaybackMeterView, context: Context) {
        view.update(isActive: animates && !reduceMotion, isPlaying: true, color: .white)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlaybackMeterView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// The expanded call, laid out as the phone's: who is on the line to the
/// left of the camera, the running time and the controls to its right, all
/// in the band the camera sits in. There is no caller, only the app holding
/// the microphone, so its icon stands in for the portrait and its name for
/// the contact.
struct IslandCallExpanded: View {
    var activity: IslandActivity
    var physicalNotchWidth: CGFloat?
    @Bindable var coordinator: AppCoordinator

    private var profile: MeetingControls.AppProfile? { MeetingControls.profile(for: activity.id.key) }
    private var showsMeetingControls: Bool { ExtrasPreferences.shared.meetingControlsEnabled }
    /// Four controls share the wing when meeting controls are on.
    private var controlDiameter: CGFloat { showsMeetingControls ? 30 : 34 }
    /// A meeting app's own state can't be read, so its slash follows the
    /// shortcuts NotchShot sent; the system mute is read from the device.
    private var isMicrophoneMuted: Bool {
        profile == nil ? coordinator.systemInputMuted : coordinator.meetingMutedApps.contains(activity.id.key)
    }

    var body: some View {
        IslandWrappingRow(
            physicalNotchWidth: physicalNotchWidth,
            height: NotchIsland.Geometry.expandedCallHeight,
            leadingInset: 12,
            trailingInset: 12
        ) {
            HStack(spacing: 9) {
                IslandCallAvatar(bundleIdentifier: activity.id.key, title: activity.title, diameter: 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text(activity.subtitle ?? "On a call")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    Text(activity.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        } trailing: {
            // The call is already live, so nothing here may look like the
            // phone's red/green answer pair: a solid green phone next to an ✕
            // read as "accept / decline". The phone's active call shows the
            // running time and a live waveform, and so does this; the two
            // controls are neutral.
            HStack(spacing: showsMeetingControls ? 6 : 8) {
                IslandCallElapsed(
                    startedAt: activity.startedAt,
                    font: .system(size: 15, weight: .semibold, design: .rounded)
                )
                .fixedSize()
                if showsMeetingControls {
                    // Mute takes the waveform's place: the meter is
                    // decoration, the button is the thing people reach for.
                    let microphone = MeetingControls.microphonePresentation(for: activity.id.key)
                    IslandRoundButton(
                        systemName: isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                        label: microphone.label,
                        tint: .white,
                        filled: false,
                        diameter: controlDiameter
                    ) {
                        coordinator.toggleMeetingMute(activity.id)
                    }
                    .help(microphone.help)
                    .islandReveal(stage: 1)
                    if profile?.camera != nil {
                        IslandRoundButton(
                            systemName: "video.fill",
                            label: "Toggle camera in \(profile?.name ?? activity.title)",
                            tint: .white,
                            filled: false,
                            diameter: controlDiameter
                        ) {
                            coordinator.toggleMeetingCamera(activity.id)
                        }
                        .help("Sends the camera shortcut. Check the call app for its current camera state.")
                        .islandReveal(stage: 1)
                    }
                } else {
                    IslandCallWaveform()
                        .fixedSize()
                        .padding(.trailing, 2)
                }
                IslandRoundButton(
                    systemName: "arrow.up.forward.app",
                    label: "Open \(activity.title)",
                    tint: .white,
                    filled: false,
                    diameter: controlDiameter
                ) {
                    coordinator.openCallApp(activity.id)
                }
                .islandReveal(stage: 1)
                IslandRoundButton(systemName: "xmark", label: "Hide call", tint: .white, filled: false, diameter: controlDiameter) {
                    coordinator.performIslandAction(.dismiss, on: activity.id)
                }
                .islandReveal(stage: 1)
            }
        }
    }
}
