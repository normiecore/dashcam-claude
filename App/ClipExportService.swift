import AVFoundation
import Foundation

/// Export is a foreground derivative. It never changes the protected originals.
/// Gaps between files are concatenated, not reconstructed; retain the originals
/// and manifest when timing evidence matters.
@MainActor
final class ClipExportService {
    private var activeExport: AVAssetExportSession?
    private var generation = 0

    func cancel() {
        generation += 1
        activeExport?.cancelExport()
    }
    enum ExportError: LocalizedError {
        case noMedia, badMedia(String), cannotExport, lowStorage, failed(String)
        var errorDescription: String? {
            switch self {
            case .noMedia: return "No finalized video is available for this incident."
            case .badMedia(let file): return "A segment is unreadable: \(file). It has been retained for recovery."
            case .cannotExport: return "This device cannot combine the selected segments."
            case .lowStorage: return "There is not enough free space for an export. Protected originals are unchanged."
            case .failed(let message): return message
            }
        }
    }

    func export(urls: [URL], incidentID: UUID) async throws -> URL {
        generation += 1
        let currentGeneration = generation
        guard !urls.isEmpty else { throw ExportError.noMedia }
        let fm = FileManager.default
        let directory = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true).appendingPathComponent("DashcamExports", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        let bytes: Int64 = try urls.reduce(0) { total, url in
            let attrs = try fm.attributesOfItem(atPath: url.path)
            return total + ((attrs[.size] as? NSNumber)?.int64Value ?? 0)
        }
        // Passthrough is normally near source size. Allow a margin and preserve
        // the same reserve used for recording; a failed write still fails closed.
        guard free > bytes + bytes / 2 + 250 * 1024 * 1024 else { throw ExportError.lowStorage }

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.cannotExport }
        var audio: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var first = true
        for url in urls {
            guard generation == currentGeneration else { throw CancellationError() }
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.badMedia(url.lastPathComponent)
            }
            let range = try await source.load(.timeRange)
            guard range.duration.isNumeric, range.duration.seconds > 0 else {
                throw ExportError.badMedia(url.lastPathComponent)
            }
            if first {
                video.preferredTransform = try await source.load(.preferredTransform)
                first = false
            }
            try video.insertTimeRange(range, of: source, at: cursor)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await sourceAudio.load(.timeRange)
                let common = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if common.duration.isNumeric, common.duration.seconds > 0 {
                    if audio == nil { audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                    guard let audio else { throw ExportError.cannotExport }
                    try audio.insertTimeRange(common, of: sourceAudio,
                                              at: cursor + common.start - range.start)
                }
            }
            cursor = cursor + range.duration
        }

        guard generation == currentGeneration else { throw CancellationError() }
        let output = directory.appendingPathComponent("incident-\(incidentID.uuidString)-\(UUID().uuidString).mov")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mov) else { throw ExportError.cannotExport }
        session.outputURL = output
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false
        activeExport = session
        defer { activeExport = nil }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    if session.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: ExportError.failed(session.error?.localizedDescription ?? "Video export did not finish.")) }
                }
            }
            return output
        } catch {
            try? fm.removeItem(at: output) // derivative only
            throw error
        }
    }
}
