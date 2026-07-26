import AppKit
import AudioToolbox
import CoreMedia
import Foundation
import Testing
@testable import NotchShotKit

@Suite("History retention")
struct HistoryRetentionTests {

    private func entry(ageDays: Double, text: String? = nil, name: String = "shot.png") -> HistoryEntry {
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            kind: .screenshot,
            pixelSize: CGSize(width: 100, height: 100),
            createdAt: Date().addingTimeInterval(-ageDays * 86_400),
            sourceApplicationName: "Safari"
        )
        return HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: text)
    }

    @Test("Entries older than the window are removed")
    func expiry() {
        let entries = [entry(ageDays: 1), entry(ageDays: 29), entry(ageDays: 31), entry(ageDays: 400)]
        let result = HistoryRepository.partitionByRetention(
            entries,
            retentionDays: 30,
            now: Date(),
            fileExists: { _ in true }
        )
        #expect(result.kept.count == 2)
        #expect(result.removed.count == 2)
    }

    @Test("A retention of zero keeps everything forever")
    func keepForever() {
        let entries = [entry(ageDays: 1), entry(ageDays: 4000)]
        let result = HistoryRepository.partitionByRetention(
            entries,
            retentionDays: 0,
            now: Date(),
            fileExists: { _ in true }
        )
        #expect(result.removed.isEmpty)
        #expect(result.kept.count == 2)
    }

    @Test("A row whose file has vanished is dropped regardless of age")
    func missingFileDropped() {
        let entries = [entry(ageDays: 0.1)]
        let result = HistoryRepository.partitionByRetention(
            entries,
            retentionDays: 30,
            now: Date(),
            fileExists: { _ in false }
        )
        #expect(result.kept.isEmpty)
        #expect(result.removed.count == 1)
    }

    @Test("Retention never deletes the capture files themselves")
    func retentionKeepsFiles() {
        // The row and its thumbnail are ours; the capture belongs to the user.
        #expect(HistoryRepository.retentionDeletesFiles == false)
    }

    @Test("An entry exactly at the boundary is kept")
    func boundaryInclusive() {
        let now = Date()
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/a.png"),
            kind: .screenshot,
            pixelSize: .zero,
            createdAt: now.addingTimeInterval(-30 * 86_400)
        )
        let result = HistoryRepository.partitionByRetention(
            [HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: nil)],
            retentionDays: 30,
            now: now,
            fileExists: { _ in true }
        )
        #expect(result.kept.count == 1)
    }

    @Test("Search matches filenames and app names")
    func searchBasics() {
        let entry = entry(ageDays: 1, name: "Invoice.png")
        #expect(entry.matches("invoice"))
        #expect(entry.matches("safari"))
        #expect(entry.matches("Screenshot"))
        #expect(!entry.matches("nonexistent"))
    }

    @Test("Recognised text is searchable only when it was indexed")
    func searchRespectsIndexingOptIn() {
        let indexed = entry(ageDays: 1, text: "confidential balance sheet")
        #expect(indexed.matches("balance"))

        // Nil indexedText models the opt-in being off at capture time.
        let notIndexed = entry(ageDays: 1, text: nil)
        #expect(!notIndexed.matches("balance"))
    }

    @Test("An empty query matches everything")
    func emptyQuery() {
        #expect(entry(ageDays: 1).matches(""))
    }

    @Test("History preserves exact generated-caption ownership")
    func captionOwnershipRoundTrip() throws {
        let captionURL = URL(fileURLWithPath: "/tmp/owned-captions.srt")
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/recording.mp4"),
            kind: .recording,
            pixelSize: CGSize(width: 1_920, height: 1_080),
            duration: 30,
            captionURL: captionURL
        )
        let original = HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: nil)
        let decoded = try JSONDecoder().decode(
            HistoryEntry.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded.captionPath == captionURL.path)
        #expect(decoded.asset.captionURL == captionURL)
    }
}

@Suite("Media snapshot")
struct MediaSnapshotTests {

    @Test("Position is interpolated forward while playing")
    func interpolationWhilePlaying() {
        let snapshot = MediaSnapshot(
            title: "Track",
            duration: 200,
            position: 30,
            positionTimestamp: Date().addingTimeInterval(-10),
            isPlaying: true
        )
        let position = snapshot.interpolatedPosition()
        #expect(position != nil)
        #expect(abs(position! - 40) < 0.5)
    }

    @Test("A paused track's position doesn't drift")
    func noInterpolationWhilePaused() {
        let snapshot = MediaSnapshot(
            title: "Track",
            duration: 200,
            position: 30,
            positionTimestamp: Date().addingTimeInterval(-60),
            isPlaying: false
        )
        #expect(snapshot.interpolatedPosition() == 30)
    }

    @Test("Interpolation is clamped to the track length")
    func interpolationClamped() {
        let snapshot = MediaSnapshot(
            title: "Track",
            duration: 40,
            position: 30,
            positionTimestamp: Date().addingTimeInterval(-600),
            isPlaying: true
        )
        #expect(snapshot.interpolatedPosition() == 40)
        #expect(snapshot.progress == 1)
    }

    @Test("A position tick is not treated as a track change")
    func dedupIgnoresPosition() {
        let base = MediaSnapshot(
            source: .mediaRemote,
            title: "Track",
            artist: "Artist",
            duration: 200,
            position: 10,
            isPlaying: true
        )
        var tick = base
        tick.position = 11
        tick.positionTimestamp = Date()
        #expect(base.isMateriallyEqual(to: tick))
    }

    @Test("A different track is a real change")
    func dedupDetectsTrackChange() {
        let a = MediaSnapshot(source: .mediaRemote, title: "One", artist: "Artist")
        var b = a
        b.title = "Two"
        #expect(!a.isMateriallyEqual(to: b))
    }

    @Test("Play/pause counts as a material change")
    func dedupDetectsPlayState() {
        let a = MediaSnapshot(source: .mediaRemote, title: "One", isPlaying: true)
        var b = a
        b.isPlaying = false
        #expect(!a.isMateriallyEqual(to: b))
    }

    @Test("Same-sized new artwork is still a material media change")
    func dedupDetectsArtworkContent() {
        let a = MediaSnapshot(
            source: .mediaRemote,
            title: "One",
            artworkData: Data([1, 2, 3])
        )
        var b = a
        b.artworkData = Data([3, 2, 1])
        #expect(!a.isMateriallyEqual(to: b))
    }

    @Test("Visible app names and command availability refresh")
    func dedupDetectsControlsAndAppName() {
        let a = MediaSnapshot(
            source: .mediaRemote,
            applicationName: "Music",
            title: "One",
            supportedCommands: [.play]
        )
        var b = a
        b.applicationName = "Spotify"
        #expect(!a.isMateriallyEqual(to: b))
        b = a
        b.supportedCommands = [.pause, .nextTrack]
        #expect(!a.isMateriallyEqual(to: b))
    }

    @Test("An empty snapshot has nothing worth showing")
    func emptyHasNoContent() {
        #expect(!MediaSnapshot.empty.hasContent)
        #expect(MediaSnapshot(source: .mediaRemote, title: "x").hasContent)
        // Source `.none` means the backend is disabled, whatever it carries.
        #expect(!MediaSnapshot(source: .none, title: "x").hasContent)
    }

    @Test("Progress is zero when the duration is unknown")
    func progressWithoutDuration() {
        #expect(MediaSnapshot(title: "x", position: 30).progress == 0)
    }
}

@Suite("Adapter payload parsing")
struct AdapterPayloadTests {

    private func snapshot(_ json: String) -> MediaSnapshot? {
        AdapterPayload.snapshot(from: Data(json.utf8))
    }

    @Test("A standard payload is parsed")
    func standardPayload() throws {
        let result = try #require(snapshot("""
        {"title":"Song","artist":"Band","album":"Record","duration":210.5,
         "elapsedTime":42.0,"playing":true,"bundleIdentifier":"com.spotify.client"}
        """))
        #expect(result.title == "Song")
        #expect(result.artist == "Band")
        #expect(result.album == "Record")
        #expect(result.duration == 210.5)
        #expect(result.position == 42)
        #expect(result.isPlaying)
        #expect(result.source == .mediaRemote)
    }

    @Test("A payload wrapped in `payload` is unwrapped")
    func wrappedPayload() throws {
        let result = try #require(snapshot("""
        {"payload":{"title":"Song","artist":"Band","playing":false}}
        """))
        #expect(result.title == "Song")
        #expect(!result.isPlaying)
    }

    @Test("Alternate key spellings still parse, so a rename degrades gracefully")
    func alternateKeys() throws {
        let result = try #require(snapshot("""
        {"title":"Song","trackArtist":"Band","currentTime":12,"isPlaying":1,
         "bundleID":"com.apple.Music"}
        """))
        #expect(result.artist == "Band")
        #expect(result.position == 12)
        #expect(result.isPlaying)
    }

    @Test("Numbers arriving as strings are accepted")
    func stringNumbers() throws {
        let result = try #require(snapshot("""
        {"title":"Song","duration":"180","elapsedTime":"20"}
        """))
        #expect(result.duration == 180)
        #expect(result.position == 20)
    }

    @Test("A payload with no track means nothing is playing")
    func emptyPayload() throws {
        let result = try #require(snapshot(#"{"bundleIdentifier":"com.apple.Safari"}"#))
        #expect(!result.hasContent)
        #expect(result.title == nil)
    }

    @Test("Malformed JSON yields nil rather than throwing into the stream")
    func malformedJSON() {
        #expect(snapshot("not json at all") == nil)
        #expect(snapshot("") == nil)
    }

    @Test("Base64 artwork is decoded")
    func artwork() throws {
        let payload = Data("hello artwork".utf8).base64EncodedString()
        let result = try #require(snapshot(#"{"title":"Song","artworkData":"\#(payload)"}"#))
        #expect(result.artworkData == Data("hello artwork".utf8))
    }

    @Test("Unparseable artwork doesn't discard the rest of the metadata")
    func badArtwork() throws {
        let result = try #require(snapshot(#"{"title":"Song","artworkData":"!!!not base64!!!"}"#))
        #expect(result.title == "Song")
    }
}

@Suite("OCR data detection")
struct DataDetectionTests {

    @Test("An email address is detected")
    func email() {
        let items = OCRService.detectItems(in: "Write to sam@example.com for access")
        #expect(items.contains { $0.kind == .email && $0.value == "sam@example.com" })
    }

    @Test("A URL is detected")
    func link() {
        let items = OCRService.detectItems(in: "See https://example.com/docs for details")
        #expect(items.contains { $0.kind == .link })
    }

    @Test("A phone number is detected")
    func phone() {
        let items = OCRService.detectItems(in: "Call +1 (555) 010-9999 today")
        #expect(items.contains { $0.kind == .phone })
    }

    @Test("Plain prose produces no false positives")
    func noDetections() {
        #expect(OCRService.detectItems(in: "Just some ordinary words here.").isEmpty)
    }

    @Test("The same address isn't reported twice")
    func deduplication() {
        let items = OCRService.detectItems(in: "sam@example.com and again sam@example.com")
        #expect(items.filter { $0.value == "sam@example.com" }.count == 1)
    }

    @Test("Detected items produce openable URLs")
    func actionURLs() {
        #expect(DetectedItem(kind: .email, value: "a@b.com").actionURL?.scheme == "mailto")
        #expect(DetectedItem(kind: .phone, value: "+1 555 0100").actionURL?.scheme == "tel")
        #expect(DetectedItem(kind: .link, value: "example.com").actionURL?.scheme == "https")
    }
}

@Suite("Recording configuration")
struct RecordingConfigurationTests {

    private func configuration(
        resolution: RecordingResolution,
        quality: RecordingQuality = .balanced,
        fps: Int = 60
    ) -> RecordingConfiguration {
        RecordingConfiguration(
            target: .display(1),
            quality: quality,
            resolution: resolution,
            framesPerSecond: fps
        )
    }

    @Test("Native resolution keeps the source pixels")
    func nativeResolution() {
        let size = configuration(resolution: .native)
            .outputPixelSize(for: CGSize(width: 3024, height: 1964))
        #expect(size == CGSize(width: 3024, height: 1964))
    }

    @Test("Downscaling preserves the aspect ratio")
    func downscale() {
        let size = configuration(resolution: .p1080)
            .outputPixelSize(for: CGSize(width: 3840, height: 2160))
        #expect(size == CGSize(width: 1920, height: 1080))
    }

    @Test("Output dimensions are always even, as H.264 requires")
    func evenDimensions() {
        for source in [CGSize(width: 1001, height: 733), CGSize(width: 3, height: 7)] {
            for resolution in RecordingResolution.allCases {
                let size = configuration(resolution: resolution).outputPixelSize(for: source)
                #expect(Int(size.width) % 2 == 0)
                #expect(Int(size.height) % 2 == 0)
            }
        }
    }

    @Test("A source smaller than the target isn't upscaled")
    func noUpscaling() {
        let size = configuration(resolution: .p2160)
            .outputPixelSize(for: CGSize(width: 640, height: 480))
        #expect(size == CGSize(width: 640, height: 480))
    }

    @Test("A zero-size source degrades to a valid minimum")
    func degenerateSource() {
        let size = configuration(resolution: .native).outputPixelSize(for: .zero)
        #expect(size.width >= 2)
        #expect(size.height >= 2)
    }

    @Test("Bitrate rises with quality and stays within sane bounds")
    func bitrateBounds() {
        let output = CGSize(width: 1920, height: 1080)
        let small = configuration(resolution: .p1080, quality: .small).averageBitRate(for: output)
        let balanced = configuration(resolution: .p1080, quality: .balanced).averageBitRate(for: output)
        let high = configuration(resolution: .p1080, quality: .high).averageBitRate(for: output)

        #expect(small < balanced)
        #expect(balanced < high)
        #expect(small >= 1_000_000)
        #expect(high <= 60_000_000)
    }

    @Test("A 5K/60 capture is capped rather than producing an absurd bitrate")
    func bitrateCap() {
        let rate = configuration(resolution: .native, quality: .high)
            .averageBitRate(for: CGSize(width: 5120, height: 2880))
        #expect(rate == 60_000_000)
    }

    @Test("Audio sources compose as flags")
    func audioSources() {
        var sources: RecordingAudioSources = []
        #expect(sources.isEmpty)
        sources.insert(.system)
        sources.insert(.microphone)
        #expect(sources.contains(.system))
        #expect(sources.contains(.microphone))
        sources.remove(.microphone)
        #expect(!sources.contains(.microphone))
    }

    @Test("Elapsed time formats with an hour component only when needed")
    func elapsedFormatting() {
        var status = RecordingStatus()
        status.elapsed = 65
        #expect(status.elapsedDescription == "01:05")
        status.elapsed = 3_725
        #expect(status.elapsedDescription == "1:02:05")
    }

    @Test("Audio meter attack, bounds, and decay are stable")
    func audioMeterEnvelope() {
        var meter = AudioLevelMeter()
        meter.push(rms: 1)
        let attacked = meter.level
        #expect(attacked > 0)
        #expect(attacked <= 1)
        meter.decay()
        #expect(meter.level < attacked)

        meter.push(rms: .infinity)
        #expect(meter.level >= 0)
        #expect(meter.level <= 1)
    }

    @Test("RMS reads every channel of a planar float sample buffer")
    func planarAudioRMS() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr)

        let values: [Float] = [0.5, 0.5, 0.5, 0.5, -0.5, -0.5, -0.5, -0.5]
        let byteCount = values.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr)
        let readyBlockBuffer = try #require(blockBuffer)
        let replaceStatus = values.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: readyBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        #expect(replaceStatus == noErr)

        let readyFormatDescription = try #require(formatDescription)
        var sampleBuffer: CMSampleBuffer?
        #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: readyBlockBuffer,
            formatDescription: readyFormatDescription,
            sampleCount: 4,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr)

        let readySampleBuffer = try #require(sampleBuffer)
        let rms = try #require(AudioLevelMeter.rootMeanSquare(of: readySampleBuffer))
        #expect(abs(rms - 0.5) < 0.001)
    }

    @Test("Recording status keeps a fixed history of real meter samples")
    func waveformHistory() {
        var status = RecordingStatus()
        status.isSystemAudioEnabled = true
        status.isMicrophoneEnabled = true

        for index in 0 ..< RecordingStatus.waveformSampleCount + 4 {
            status.appendMeterSnapshot(
                system: Float(index) / 10,
                microphone: Float(index) / 20
            )
        }

        #expect(status.systemWaveform.count == RecordingStatus.waveformSampleCount)
        #expect(status.microphoneWaveform.count == RecordingStatus.waveformSampleCount)
        #expect(status.systemWaveform.last == 1)
        #expect(status.microphoneWaveform.last == 1)
        #expect(status.systemWaveform.contains(where: { $0 > 0 }))
    }

    @Test("Disabled audio sources publish silence")
    func disabledWaveformIsSilent() {
        var status = RecordingStatus()
        status.appendMeterSnapshot(system: 0.9, microphone: 0.8)
        #expect(status.systemLevel == 0)
        #expect(status.microphoneLevel == 0)
        #expect(status.systemWaveform.allSatisfy { $0 == 0 })
        #expect(status.microphoneWaveform.allSatisfy { $0 == 0 })
    }
}
