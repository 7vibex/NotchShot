import AVFoundation
import CoreMedia
import Foundation

/// Joins pause/resume segments without decoding them. All segments originate
/// from the same RecordingConfiguration, so their track geometry and codecs
/// are intentionally compatible.
enum RecordingSegmentJoiner {
    static func join(_ urls: [URL], to destination: URL) async throws {
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
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

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
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
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
        try await exporter.export(to: destination, as: .mp4)
    }
}
