import Foundation

/// Minimal ISO BMFF (MP4) box tooling for the fragmented MP4 segments AVAssetWriter emits.
///
/// Why this exists: every media segment's `tfdt` (track fragment decode time) is measured from the
/// start of the recording run. An incident clip assembled from segments recorded three minutes into a
/// run would therefore start with three minutes of empty timeline. `rebase` shifts every fragment so
/// the earliest included sample starts at zero while preserving relative timing between tracks. Sizes
/// never change, so byte offsets inside `moof`/`trun` stay valid.
public enum FMP4 {
    public struct Box: Equatable {
        public let type: String
        /// Whole box, header included, as offsets from the start of the data.
        public let range: Range<Int>
        /// Payload after the (possibly 64-bit) header.
        public let payload: Range<Int>
    }

    public enum ParseError: Error, Equatable {
        case truncated(String)
        case invalidSize(String)
        case valueOverflow(String)
    }

    public struct TimeField: Equatable {
        public enum Kind: Equatable { case trackFragmentDecodeTime, segmentIndex }
        public let trackID: UInt32
        /// Offset of the time value within the segment data.
        public let offset: Int
        public let is64Bit: Bool
        public let value: UInt64
        public let kind: Kind
    }

    public struct RebasePlan: Equatable {
        /// Wall-timeline position (seconds) of the earliest sample; becomes zero after rebasing.
        public let originSeconds: Double
        /// Ticks to subtract per track (in that track's timescale).
        public let deltas: [UInt32: UInt64]
    }

    // MARK: Box walking

    public static func boxes(in data: Data, range: Range<Int>? = nil) throws -> [Box] {
        let bounds = range ?? 0..<data.count
        var result: [Box] = []
        var offset = bounds.lowerBound
        while offset < bounds.upperBound {
            guard bounds.upperBound - offset >= 8 else { throw ParseError.truncated("box header at \(offset)") }
            var size = Int(readUInt32(data, at: offset))
            let type = readType(data, at: offset + 4)
            var headerSize = 8
            if size == 1 {
                guard bounds.upperBound - offset >= 16 else { throw ParseError.truncated("largesize at \(offset)") }
                let large = readUInt64(data, at: offset + 8)
                guard large <= UInt64(Int.max) else { throw ParseError.invalidSize(type) }
                size = Int(large)
                headerSize = 16
            } else if size == 0 {
                size = bounds.upperBound - offset
            }
            guard size >= headerSize, offset + size <= bounds.upperBound else {
                throw ParseError.invalidSize("\(type) at \(offset) size \(size)")
            }
            result.append(Box(type: type, range: offset..<(offset + size), payload: (offset + headerSize)..<(offset + size)))
            offset += size
        }
        return result
    }

    /// track_ID -> media timescale, from the initialization segment's `moov`.
    public static func trackTimescales(initializationSegment data: Data) throws -> [UInt32: UInt32] {
        var result: [UInt32: UInt32] = [:]
        for moov in try boxes(in: data) where moov.type == "moov" {
            for trak in try boxes(in: data, range: moov.payload) where trak.type == "trak" {
                var trackID: UInt32?
                var timescale: UInt32?
                for child in try boxes(in: data, range: trak.payload) {
                    switch child.type {
                    case "tkhd":
                        let version = byte(data, child.payload.lowerBound)
                        // FullBox header (4) + creation/modification times (8 or 16) + track_ID
                        trackID = readUInt32(data, at: child.payload.lowerBound + 4 + (version == 1 ? 16 : 8))
                    case "mdia":
                        for mdhd in try boxes(in: data, range: child.payload) where mdhd.type == "mdhd" {
                            let version = byte(data, mdhd.payload.lowerBound)
                            timescale = readUInt32(data, at: mdhd.payload.lowerBound + 4 + (version == 1 ? 16 : 8))
                        }
                    default:
                        continue
                    }
                }
                if let trackID, let timescale { result[trackID] = timescale }
            }
        }
        return result
    }

    /// Every rebasable time value in a media segment: `moof/traf/tfdt` and `sidx` earliest presentation times.
    public static func timeFields(mediaSegment data: Data) throws -> [TimeField] {
        var fields: [TimeField] = []
        for box in try boxes(in: data) {
            switch box.type {
            case "moof":
                for traf in try boxes(in: data, range: box.payload) where traf.type == "traf" {
                    var trackID: UInt32?
                    var decodeTime: (offset: Int, is64: Bool, value: UInt64)?
                    for child in try boxes(in: data, range: traf.payload) {
                        switch child.type {
                        case "tfhd":
                            trackID = readUInt32(data, at: child.payload.lowerBound + 4)
                        case "tfdt":
                            let version = byte(data, child.payload.lowerBound)
                            let offset = child.payload.lowerBound + 4
                            if version == 1 {
                                decodeTime = (offset, true, readUInt64(data, at: offset))
                            } else {
                                decodeTime = (offset, false, UInt64(readUInt32(data, at: offset)))
                            }
                        default:
                            continue
                        }
                    }
                    if let trackID, let decodeTime {
                        fields.append(TimeField(trackID: trackID, offset: decodeTime.offset, is64Bit: decodeTime.is64, value: decodeTime.value, kind: .trackFragmentDecodeTime))
                    }
                }
            case "sidx":
                let version = byte(data, box.payload.lowerBound)
                let referenceID = readUInt32(data, at: box.payload.lowerBound + 4)
                let offset = box.payload.lowerBound + 12 // FullBox header + reference_ID + timescale
                if version == 1 {
                    fields.append(TimeField(trackID: referenceID, offset: offset, is64Bit: true, value: readUInt64(data, at: offset), kind: .segmentIndex))
                } else {
                    fields.append(TimeField(trackID: referenceID, offset: offset, is64Bit: false, value: UInt64(readUInt32(data, at: offset)), kind: .segmentIndex))
                }
            default:
                continue
            }
        }
        return fields
    }

    // MARK: Rebasing

    /// Chooses a single origin (the earliest decode time across tracks, in seconds) so relative A/V
    /// timing is preserved, and converts it to per-track tick deltas.
    public static func rebasePlan(timescales: [UInt32: UInt32], fields: [TimeField]) -> RebasePlan? {
        var origin = Double.infinity
        for field in fields where field.kind == .trackFragmentDecodeTime {
            guard let timescale = timescales[field.trackID], timescale > 0 else { continue }
            origin = min(origin, Double(field.value) / Double(timescale))
        }
        guard origin.isFinite else { return nil }
        var deltas: [UInt32: UInt64] = [:]
        for (track, timescale) in timescales {
            deltas[track] = UInt64((origin * Double(timescale)).rounded())
        }
        return RebasePlan(originSeconds: origin, deltas: deltas)
    }

    public static func apply(_ plan: RebasePlan, to segment: inout Data, fields: [TimeField]) throws {
        for field in fields {
            guard let delta = plan.deltas[field.trackID] else { continue }
            let newValue = field.value >= delta ? field.value - delta : 0
            if field.is64Bit {
                writeUInt64(&segment, newValue, at: field.offset)
            } else {
                guard newValue <= UInt64(UInt32.max) else { throw ParseError.valueOverflow("tfdt for track \(field.trackID)") }
                writeUInt32(&segment, UInt32(newValue), at: field.offset)
            }
        }
    }

    /// Reads the segments, computes one rebase plan for the whole clip, and returns it. Returns nil when
    /// the data is not parseable fMP4 (callers then fall back to a plain concatenation).
    public static func rebasePlan(initialization: URL, mediaSegments: [URL]) -> RebasePlan? {
        guard let initData = try? Data(contentsOf: initialization, options: .mappedIfSafe),
              let timescales = try? trackTimescales(initializationSegment: initData), !timescales.isEmpty else { return nil }
        var fields: [TimeField] = []
        for url in mediaSegments {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let found = try? timeFields(mediaSegment: data) else { return nil }
            fields.append(contentsOf: found)
        }
        return rebasePlan(timescales: timescales, fields: fields)
    }

    // MARK: Byte helpers (offsets are relative to the start of the data, whatever its startIndex)

    static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value = (value << 8) | UInt32(byte(data, offset + i)) }
        return value
    }

    static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(byte(data, offset + i)) }
        return value
    }

    static func readType(_ data: Data, at offset: Int) -> String {
        let bytes = (0..<4).map { byte(data, offset + $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func writeUInt32(_ data: inout Data, _ value: UInt32, at offset: Int) {
        for i in 0..<4 { data[data.startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (3 - i))) }
    }

    static func writeUInt64(_ data: inout Data, _ value: UInt64, at offset: Int) {
        for i in 0..<8 { data[data.startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (7 - i))) }
    }
}
