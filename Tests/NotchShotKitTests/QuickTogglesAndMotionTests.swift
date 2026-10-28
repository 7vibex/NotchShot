import AppKit
import CoreAudio
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import NotchShotKit

@Suite("Instant Replay buffer")
struct InstantReplayBufferTests {
    @Test("Keeps the newest segments that still cover the window")
    func trimsToWindow() {
        var buffer = InstantReplayBuffer(window: 3)
        buffer.setInitialization(Data([0xFF]))
        for index in 1 ... 5 { buffer.append(Data([UInt8(index)]), duration: 1) }
        #expect(buffer.bufferedDuration == 3)
        #expect(buffer.movieData() == Data([0xFF, 3, 4, 5]))
    }

    @Test("Never shorter than asked for: uneven segments keep one extra")
    func neverShort() {
        var buffer = InstantReplayBuffer(window: 3)
        buffer.setInitialization(Data([0]))
        for _ in 0 ..< 4 { buffer.append(Data([1]), duration: 1.4) }
        #expect(buffer.bufferedDuration >= 3)
        #expect(buffer.bufferedDuration < 3 + 1.4)
    }

    @Test("Nothing to save before the first segment, or without an initialization segment")
    func emptyStates() {
        var buffer = InstantReplayBuffer(window: 30)
        #expect(buffer.movieData() == nil)
        buffer.append(Data([1]), duration: 1)
        #expect(buffer.isEmpty)
        buffer.setInitialization(Data([0]))
        #expect(buffer.movieData() == nil)
    }

    @Test("A new writer's initialization drops the old writer's segments")
    func newInitializationResets() {
        var buffer = InstantReplayBuffer(window: 30)
        buffer.setInitialization(Data([0]))
        buffer.append(Data([1]), duration: 1)
        buffer.setInitialization(Data([9]))
        #expect(buffer.segments.isEmpty)
        buffer.append(Data([2]), duration: 1)
        #expect(buffer.movieData() == Data([9, 2]))
    }

    @Test("The encoded picture is at most 1920 wide, in even numbers")
    func encodedSize() {
        let retina = InstantReplayRecorder.Settings.encodedSize(forDisplayPixels: CGSize(width: 3456, height: 2234))
        #expect(retina.width == 1920)
        #expect(retina.height.truncatingRemainder(dividingBy: 2) == 0)
        #expect(abs(retina.height - 1241) <= 1)
        let small = CGSize(width: 1280, height: 800)
        #expect(InstantReplayRecorder.Settings.encodedSize(forDisplayPixels: small) == small)
    }

    @Test("Bit rate stays between 3 and 8 Mbit/s")
    func bitRate() {
        let tiny = InstantReplayRecorder.Settings(window: 30, includesSystemAudio: false, pixelSize: CGSize(width: 640, height: 400))
        let large = InstantReplayRecorder.Settings(window: 30, includesSystemAudio: false, pixelSize: CGSize(width: 1920, height: 1242))
        #expect(tiny.videoBitRate == 3_000_000)
        #expect(large.videoBitRate > 3_000_000 && large.videoBitRate <= 8_000_000)
    }
}

@Suite("Keep Awake and Clean Keyboard")
struct KeepAwakeAndKeyboardTests {
    @Test("Each mode holds the assertion it should, and only while it should")
    func assertions() {
        let now = Date()
        let display = kIOPMAssertPreventUserIdleDisplaySleep as String
        let system = kIOPMAssertPreventUserIdleSystemSleep as String
        #expect(KeepAwakeMode.assertionType(for: .off, agentsWorking: true, now: now) == nil)
        #expect(KeepAwakeMode.assertionType(for: .until(now.addingTimeInterval(60)), agentsWorking: false, now: now) == display)
        #expect(KeepAwakeMode.assertionType(for: .until(now.addingTimeInterval(-1)), agentsWorking: false, now: now) == nil)
        #expect(KeepAwakeMode.assertionType(for: .indefinitely, agentsWorking: false, now: now) == display)
        #expect(KeepAwakeMode.assertionType(for: .whileAgentsWork, agentsWorking: false, now: now) == nil)
        #expect(KeepAwakeMode.assertionType(for: .whileAgentsWork, agentsWorking: true, now: now) == system)
    }

    @Test("Timed choices last 15 minutes and an hour")
    func durations() {
        #expect(KeepAwakeChoice.fifteenMinutes.duration == TimeInterval(900))
        #expect(KeepAwakeChoice.oneHour.duration == TimeInterval(3600))
        #expect(KeepAwakeChoice.untilTurnedOff.duration == nil)
    }

    @Test("The lock swallows keys and media keys but never the mouse")
    func keyboardPolicy() {
        let systemDefined = KeyboardCleaningPolicy.systemDefined
        #expect(KeyboardCleaningPolicy.swallows(type: .keyDown, systemDefinedSubtype: nil))
        #expect(KeyboardCleaningPolicy.swallows(type: .keyUp, systemDefinedSubtype: nil))
        #expect(KeyboardCleaningPolicy.swallows(type: .flagsChanged, systemDefinedSubtype: nil))
        #expect(KeyboardCleaningPolicy.swallows(type: systemDefined, systemDefinedSubtype: 8))
        // Subtype 7 carries mouse-button state; it must keep flowing.
        #expect(!KeyboardCleaningPolicy.swallows(type: systemDefined, systemDefinedSubtype: 7))
        #expect(!KeyboardCleaningPolicy.swallows(type: .leftMouseDown, systemDefinedSubtype: nil))
        #expect(!KeyboardCleaningPolicy.swallows(type: .scrollWheel, systemDefinedSubtype: nil))
    }

    @Test("The save shortcut doesn't collide with another default")
    func replayShortcut() throws {
        let binding = try #require(HotKeyAction.saveInstantReplay.defaultBinding)
        let others = HotKeyAction.allCases.filter { $0 != .saveInstantReplay }.compactMap(\.defaultBinding)
        #expect(!others.contains(binding))
    }
}

@Suite("Notch status glyphs")
@MainActor
struct NotchStatusGlyphTests {
    @Test("A locked keyboard comes first, and the strip holds two")
    func ordering() {
        #expect(NotchStatusGlyphPolicy.glyphs(keyboardLocked: true, replayBuffering: true, keepingAwake: true)
            == [.keyboardLocked, .instantReplay])
        #expect(NotchStatusGlyphPolicy.glyphs(keyboardLocked: false, replayBuffering: false, keepingAwake: true)
            == [.keepAwake])
        #expect(NotchStatusGlyphPolicy.glyphs(keyboardLocked: false, replayBuffering: false, keepingAwake: false).isEmpty)
    }

    @Test("No wings without a physical notch")
    func noNotch() {
        #expect(!NotchStatusGlyphPolicy.showsIndicatorWings(hasPhysicalNotch: false))
    }
}

@Suite("One-time codes")
struct OneTimeCodeTests {
    @Test("Finds the code in the usual phrasings", arguments: [
        ("Your verification code is 482913", "482913"),
        ("G-482913 is your Google verification code.", "482913"),
        ("Your code: 482 913", "482913"),
        ("Your Apple Account code is: 123456. Don't share it.", "123456"),
        ("Use 7741 to sign in", "7741"),
        ("Tu código es 5521", "5521"),
    ])
    func finds(text: String, code: String) {
        #expect(OneTimeCodeDetector.code(in: text) == code)
    }

    @Test("Leaves ordinary numbers alone", arguments: [
        "Your order 48291 has shipped",
        "Call 555-123-4567 to verify",
        "Code of Conduct 2026 update",
        "Shopping list 4829",
        "Card ending 4242 1234 5678 9010 was used",
        "See you at 1830",
    ])
    func ignores(text: String) {
        #expect(OneTimeCodeDetector.code(in: text) == nil)
    }
}

@Suite("Break nudges")
struct BreakNudgeScheduleTests {
    @Test("Due after its minutes of use, one at a time")
    func dueInTurn() {
        var schedule = BreakNudgeSchedule()
        let everyMinute: (BreakNudgeKind) -> Int = { _ in 1 }
        #expect(schedule.sample(interval: 30, idleSeconds: 0, minutes: everyMinute, canNudge: true) == nil)
        #expect(schedule.sample(interval: 30, idleSeconds: 0, minutes: everyMinute, canNudge: true) == .blink)
        #expect(schedule.pending == [.water, .stand])
        #expect(schedule.sample(interval: 30, idleSeconds: 0, minutes: everyMinute, canNudge: true) == .water)
    }

    @Test("Held during a call, then shown when it ends")
    func heldWhileBusy() {
        var schedule = BreakNudgeSchedule()
        let minutes: (BreakNudgeKind) -> Int = { $0 == .blink ? 1 : 60 }
        _ = schedule.sample(interval: 30, idleSeconds: 0, minutes: minutes, canNudge: false)
        #expect(schedule.sample(interval: 30, idleSeconds: 0, minutes: minutes, canNudge: false) == nil)
        #expect(schedule.pending == [.blink])
        #expect(schedule.sample(interval: 30, idleSeconds: 0, minutes: minutes, canNudge: true) == .blink)
    }

    @Test("A real break clears what was waiting")
    func breakClears() {
        var schedule = BreakNudgeSchedule()
        let everyMinute: (BreakNudgeKind) -> Int = { _ in 1 }
        _ = schedule.sample(interval: 30, idleSeconds: 0, minutes: everyMinute, canNudge: false)
        _ = schedule.sample(interval: 30, idleSeconds: 0, minutes: everyMinute, canNudge: false)
        #expect(schedule.pending.count == 3)
        #expect(schedule.sample(interval: 30, idleSeconds: 6 * 60, minutes: everyMinute, canNudge: true) == nil)
        #expect(schedule.pending.isEmpty)
    }
}

@Suite("Scroll, swipe and stretch")
struct IslandMotionInputTests {
    @Test("A key against the end of the scale bumps; one that moves it doesn't")
    func levelBump() {
        #expect(SystemLevelBump.at(current: 1, increasing: true, sequence: 1)?.edge == .top)
        #expect(SystemLevelBump.at(current: 0, increasing: false, sequence: 1)?.edge == .bottom)
        #expect(SystemLevelBump.at(current: 0.5, increasing: true, sequence: 1) == nil)
        #expect(SystemLevelBump.at(current: 0, increasing: true, sequence: 1) == nil)
        #expect(SystemLevelBump.at(current: 1, increasing: false, sequence: 1) == nil)
    }

    @Test("Scrolling a timer adds minutes, but never below one or past a day")
    func timerMinutes() {
        #expect(FocusTimerPolicy.adjustedRemaining(300, byMinutes: 1, elapsed: 0) == 360)
        #expect(FocusTimerPolicy.adjustedRemaining(90, byMinutes: -1, elapsed: 0) == 60)
        #expect(FocusTimerPolicy.adjustedRemaining(40, byMinutes: -1, elapsed: 0) == 40)
        #expect(FocusTimerPolicy.adjustedRemaining(86_000, byMinutes: 60, elapsed: 400) == 86_000)
    }

    @Test("A trackpad steps every 12 points and carries the rest")
    func stepper() {
        var stepper = IslandScrollStepper()
        #expect(stepper.steps(adding: 5) == 0)
        #expect(stepper.steps(adding: 8) == 1)
        #expect(stepper.steps(adding: -30) == -2)
        #expect(IslandScrollStepper.wheelSteps(upward: 3) == 1)
        #expect(IslandScrollStepper.wheelSteps(upward: -0.5) == -1)
        #expect(IslandScrollStepper.wheelSteps(upward: 0) == 0)
    }

    @Test("A decisive sideways swipe skips; a wander doesn't")
    func trackSwipe() {
        var next = TrackSwipeDecision()
        next.add(deltaX: -50, deltaY: 5)
        #expect(next.command == .nextTrack)
        var previous = TrackSwipeDecision()
        previous.add(deltaX: 60, deltaY: 10)
        #expect(previous.command == .previousTrack)
        var short = TrackSwipeDecision()
        short.add(deltaX: 30, deltaY: 0)
        #expect(short.command == nil)
        var diagonal = TrackSwipeDecision()
        diagonal.add(deltaX: 60, deltaY: 50)
        #expect(diagonal.command == nil)
    }

    @Test("The lean follows the pointer in eighths")
    func lean() {
        #expect(IslandPointerLean.lean(atX: 0, width: 100) == -1)
        #expect(IslandPointerLean.lean(atX: 50, width: 100) == 0)
        #expect(IslandPointerLean.lean(atX: 100, width: 100) == 1)
        #expect(IslandPointerLean.lean(atX: 60, width: 100) == 0.25)
        #expect(IslandPointerLean.lean(atX: 500, width: 100) == 1)
        #expect(IslandPointerLean.lean(atX: 10, width: 0) == 0)
    }
}

@Suite("Per-app volume renderer")
struct AppVolumeRendererTests {
    /// Interleaved float buffers; `fill(buffer, frame, channel)`.
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        init(channels: [Int], frames: Int, fill: (Int, Int, Int) -> Float) {
            list = AudioBufferList.allocate(maximumBuffers: channels.count)
            for (index, count) in channels.enumerated() {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * count)
                for frame in 0 ..< frames {
                    for channel in 0 ..< count { data[frame * count + channel] = fill(index, frame, channel) }
                }
                storage.append(data)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(count),
                    mDataByteSize: UInt32(frames * count * MemoryLayout<Float>.size),
                    mData: data
                )
            }
        }

        func sample(buffer: Int, frame: Int, channel: Int) -> Float {
            let count = Int(list[buffer].mNumberChannels)
            return storage[buffer][frame * count + channel]
        }

        deinit {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    @Test("Stereo is copied at the chosen level")
    func scalesStereo() {
        let input = Buffers(channels: [2], frames: 4) { _, _, channel in channel == 0 ? 0.8 : -0.4 }
        let output = Buffers(channels: [2], frames: 4) { _, _, _ in 9 }
        AppVolumeRenderer.render(input: input.list, output: output.list, tapChannels: 2, from: 0.5, to: 0.5)
        #expect(output.sample(buffer: 0, frame: 2, channel: 0) == 0.4)
        #expect(output.sample(buffer: 0, frame: 2, channel: 1) == -0.2)
    }

    @Test("A headset's microphone, listed first, is never played back")
    func skipsMicrophone() {
        // Buffer 0 is the microphone (mono, loud); buffer 1 is the tap.
        let input = Buffers(channels: [1, 2], frames: 2) { buffer, _, _ in buffer == 0 ? 1 : 0.25 }
        let output = Buffers(channels: [2], frames: 2) { _, _, _ in 9 }
        AppVolumeRenderer.render(input: input.list, output: output.list, tapChannels: 2, from: 1, to: 1)
        #expect(output.sample(buffer: 0, frame: 1, channel: 0) == 0.25)
        #expect(output.sample(buffer: 0, frame: 1, channel: 1) == 0.25)
    }

    @Test("Extra output channels stay silent, and zero is silence")
    func silence() {
        let input = Buffers(channels: [2], frames: 2) { _, _, _ in 0.5 }
        let surround = Buffers(channels: [6], frames: 2) { _, _, _ in 9 }
        AppVolumeRenderer.render(input: input.list, output: surround.list, tapChannels: 2, from: 1, to: 1)
        #expect(surround.sample(buffer: 0, frame: 0, channel: 1) == 0.5)
        #expect(surround.sample(buffer: 0, frame: 0, channel: 4) == 0)

        let muted = Buffers(channels: [2], frames: 2) { _, _, _ in 9 }
        AppVolumeRenderer.render(input: input.list, output: muted.list, tapChannels: 2, from: 0, to: 0)
        #expect(muted.sample(buffer: 0, frame: 1, channel: 0) == 0)
    }

    @Test("A level change ramps across the buffer instead of jumping")
    func ramps() {
        let input = Buffers(channels: [1], frames: 4) { _, _, _ in 1 }
        let output = Buffers(channels: [1], frames: 4) { _, _, _ in 9 }
        AppVolumeRenderer.render(input: input.list, output: output.list, tapChannels: 1, from: 0, to: 1)
        #expect(output.sample(buffer: 0, frame: 0, channel: 0) == 0.25)
        #expect(output.sample(buffer: 0, frame: 3, channel: 0) == 1)
    }
}
