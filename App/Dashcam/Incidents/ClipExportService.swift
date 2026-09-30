import AVFoundation
import Foundation
import Photos
import DashcamCore

enum ClipExportError: LocalizedError {
    case unreadableClip(String)
    case photosAccessDenied
    case exportUnsupported

    var errorDescription: String? {
        switch self {
        case .unreadableClip(let detail): return "The assembled clip could not be read: \(detail)"
        case .photosAccessDenied: return "Photos access was not granted."
        case .exportUnsupported: return "Passthrough export is not supported for this clip."
        }
    }
}

/// Turns an incident's fMP4 parts into shareable clips.
///
/// Step 1 writes init segment + media segments as one fragmented MP4 with the fragment timestamps
/// rebased so the clip starts at zero even when it begins minutes into a run (see
/// `FMP4ClipAssembler.writeClip`). Step 2 remuxes it with a passthrough export into a conventional
/// MP4 (moov up front, no fragments) so Photos, AirDrop and desktop players handle it without
/// surprises. If step 2 fails the fragmented file is kept: it is still playable by AVFoundation.
struct ClipExportService: ClipAssembler {
    let logger: DashcamLogger

    func assemble(_ plan: ClipAssemblyPlan, into outputDirectory: URL, baseName: String) async throws -> [String] {
        guard !plan.isEmpty else { throw DashcamCoreError.emptyAssemblyPlan }
        var outputs: [String] = []
        let groups = plan.groups.filter { !$0.media.isEmpty }
        for (index, group) in groups.enumerated() {
            guard let initialization = group.initialization else {
                throw DashcamCoreError.missingInitializationSegment(group.run)
            }
            let suffix = groups.count == 1 ? "" : "-part\(index + 1)"
            let finalName = "\(baseName)\(suffix).mp4"
            let fragmentedURL = outputDirectory.appendingPathComponent(".\(baseName)\(suffix).fmp4.mp4")
            let finalURL = outputDirectory.appendingPathComponent(finalName)

            let rebase = try FMP4ClipAssembler.writeClip(initialization: initialization, mediaSegments: group.media, to: fragmentedURL)
            logger.info(.export, "Assembled \(group.media.count) segments (\(Int(group.duration))s) for run \(group.run); rebased=\(rebase != nil)")

            do {
                try await remux(fragmentedURL, to: finalURL)
                try? FileManager.default.removeItem(at: fragmentedURL)
                logger.notice(.export, "Exported \(finalName)")
            } catch {
                // Keep the fragmented file as the deliverable rather than losing footage.
                logger.error(.export, "Passthrough remux failed (\(error)); keeping fragmented MP4 as \(finalName)")
                if FileManager.default.fileExists(atPath: finalURL.path) { try? FileManager.default.removeItem(at: finalURL) }
                try FileManager.default.moveItem(at: fragmentedURL, to: finalURL)
            }
            outputs.append(finalName)
        }
        return outputs
    }

    func remux(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.seconds > 0 else {
            throw ClipExportError.unreadableClip("zero duration")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ClipExportError.exportUnsupported
        }
        guard session.supportedFileTypes.contains(.mp4) else { throw ClipExportError.exportUnsupported }
        session.shouldOptimizeForNetworkUse = true
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try await session.export(to: destination, as: .mp4)
    }

    // MARK: Photos

    /// Adds a clip to the Photos library (add-only access). A clip kept as fragmented MP4 because the
    /// remux failed at export time may be rejected by the Photos importer; in that case the remux is
    /// retried into a temporary file and that file is added instead.
    func saveToPhotos(_ url: URL) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw ClipExportError.photosAccessDenied }
        do {
            try await ClipExportService.addToPhotos(url)
        } catch {
            logger.warning(.export, "Photos rejected \(url.lastPathComponent) (\(error)); retrying through a passthrough remux")
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await remux(url, to: temporary)
            try await ClipExportService.addToPhotos(temporary)
        }
    }

    private static func addToPhotos(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }
}
