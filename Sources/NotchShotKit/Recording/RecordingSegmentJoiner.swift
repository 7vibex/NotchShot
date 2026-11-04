import AVFoundation
import CoreMedia
import Foundation

/// Joins pause/resume segments without decoding them. All segments originate
/// from the same RecordingConfiguration, so their track geometry and codecs
/// are intentionally compatible.
///
/// The caller deletes the segments once this returns, so the joined file is
/// checked in a private staging folder and only then appears at `destination`.
enum RecordingSegmentJoiner {
    /// Returns where the joined file landed. `destination` was only free when
    /// it was picked, and a join can take long enough for that to change.
    @discardableResult
    static func join(_ urls: [URL], to destination: URL) async throws -> URL {
        guard !urls.isEmpty else {
            throw NotchShotError.recordingFailed("There are no recording segments to join")
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NotchShotError.recordingFailed("Could not create the joined video track")
        }
        // One track per source track position. With system audio and the
        // microphone both on, a segment can carry each as its own track, and
        // keeping only the first would lose the other for good.
        var audioTracks: [AVMutableCompositionTrack] = []

        var cursor = CMTime.zero
        var firstVideoTransform: CGAffineTransform?
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.isNumeric, duration > .zero else {
                throw NotchShotError.recordingFailed("A paused recording segment has no playable duration")
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw NotchShotError.recordingFailed("A paused recording segment has no video track")
            }
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if firstVideoTransform == nil {
                firstVideoTransform = try await sourceVideo.load(.preferredTransform)
            }
            for (index, sourceAudio) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                if index == audioTracks.count {
                    guard let track = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        throw NotchShotError.recordingFailed("Could not create a joined audio track")
                    }
                    audioTracks.append(track)
                }
                // An audio track can start late or end early inside its segment;
                // keep it where it was against the video.
                let audioRange = try await sourceAudio.load(.timeRange).intersection(range)
                guard audioRange.isValid, !audioRange.isEmpty else { continue }
                try audioTracks[index].insertTimeRange(
                    audioRange,
                    of: sourceAudio,
                    at: CMTimeAdd(cursor, audioRange.start)
                )
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        if let firstVideoTransform {
            videoTrack.preferredTransform = firstVideoTransform
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw NotchShotError.recordingFailed("Could not prepare the joined recording")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staging = try RecordingExportService.stagingURL(for: destination, fileExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        try await exporter.export(to: staging, as: .mp4)
        try await validate(staging, expectedDuration: cursor.seconds, audioTrackCount: audioTracks.count)
        return try publish(staging, to: destination)
    }

    /// Never replaces a file: one that took the name during the join is not ours.
    static func publish(_ staging: URL, to destination: URL) throws -> URL {
        var target = destination
        while true {
            do {
                try RecordingExportService.publishOutputWithoutReplacing(at: staging, to: target)
                return target
            } catch let error as POSIXError where error.code == .EEXIST {
                target = AppPaths.uniqueURL(
                    in: destination.deletingLastPathComponent(),
                    name: destination.deletingPathExtension().lastPathComponent,
                    extension: destination.pathExtension,
                    alsoAvoiding: ["srt"]
                )
            }
        }
    }

    /// Throws unless the join is a whole recording. The same bar the normal stop
    /// path applies before it trusts a file, plus "nothing was dropped".
    private static func validate(
        _ url: URL,
        expectedDuration: TimeInterval,
        audioTrackCount: Int
    ) async throws {
        let joined = AVURLAsset(url: url)
        guard try await joined.load(.isPlayable),
              try await !joined.loadTracks(withMediaType: .video).isEmpty else {
            throw NotchShotError.recordingFailed("The joined recording is not playable, so its parts were kept")
        }
        let audioTracks = try await joined.loadTracks(withMediaType: .audio)
        guard audioTracks.count >= audioTrackCount else {
            throw NotchShotError.recordingFailed("The joined recording lost an audio track, so its parts were kept")
        }
        let duration = try await joined.load(.duration).seconds
        guard duration.isFinite, abs(duration - expectedDuration) <= 1 else {
            throw NotchShotError.recordingFailed("The joined recording is the wrong length, so its parts were kept")
        }
    }
}
