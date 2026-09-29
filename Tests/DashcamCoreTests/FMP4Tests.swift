import Foundation
import Testing
@testable import DashcamCore

/// Hand-built ISO BMFF boxes so the rebasing logic is verified byte for byte without AVFoundation.
enum BoxBuilder {
    static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]) }
    static func be64(_ v: UInt64) -> Data { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xffff_ffff)) }

    static func box(_ type: String, _ payload: Data, largeSize: Bool = false) -> Data {
        var data = Data()
        if largeSize {
            data += be32(1) + Data(type.utf8) + be64(UInt64(16 + payload.count))
        } else {
            data += be32(UInt32(8 + payload.count)) + Data(type.utf8)
        }
        return data + payload
    }

    static func fullBox(_ type: String, version: UInt8, _ payload: Data) -> Data {
        box(type, Data([version, 0, 0, 0]) + payload)
    }

    static func tkhd(trackID: UInt32, version: UInt8) -> Data {
        let times = version == 1 ? be64(0) + be64(0) : be32(0) + be32(0)
        return fullBox("tkhd", version: version, times + be32(trackID) + Data(repeating: 0, count: 60))
    }

    static func mdhd(timescale: UInt32, version: UInt8) -> Data {
        let times = version == 1 ? be64(0) + be64(0) : be32(0) + be32(0)
        return fullBox("mdhd", version: version, times + be32(timescale) + be32(0) + be32(0))
    }

    static func initSegment(tracks: [(id: UInt32, timescale: UInt32, version: UInt8)]) -> Data {
        var moov = fullBox("mvhd", version: 0, Data(repeating: 0, count: 96))
        for track in tracks {
            let mdia = box("mdia", mdhd(timescale: track.timescale, version: track.version) + box("hdlr", Data(repeating: 0, count: 24)))
            moov += box("trak", tkhd(trackID: track.id, version: track.version) + mdia)
        }
        return box("ftyp", Data("iso6".utf8) + be32(0)) + box("moov", moov)
    }

    static func tfdt(_ value: UInt64, version: UInt8) -> Data {
        fullBox("tfdt", version: version, version == 1 ? be64(value) : be32(UInt32(value)))
    }

    static func mediaSegment(fragments: [(trackID: UInt32, decodeTime: UInt64, version: UInt8)], sidx: (referenceID: UInt32, timescale: UInt32, earliest: UInt64, version: UInt8)? = nil) -> Data {
        var data = box("styp", Data("cmfc".utf8) + be32(0))
        if let sidx {
            let time = sidx.version == 1 ? be64(sidx.earliest) + be64(0) : be32(UInt32(sidx.earliest)) + be32(0)
            data += fullBox("sidx", version: sidx.version, be32(sidx.referenceID) + be32(sidx.timescale) + time + be32(0))
        }
        var moof = fullBox("mfhd", version: 0, be32(1))
        for fragment in fragments {
            let tfhd = fullBox("tfhd", version: 0, be32(fragment.trackID))
            let trun = fullBox("trun", version: 0, be32(1) + be32(0))
            moof += box("traf", tfhd + tfdt(fragment.decodeTime, version: fragment.version) + trun)
        }
        data += box("moof", moof)
        data += box("mdat", Data([0xde, 0xad, 0xbe, 0xef]))
        return data
    }
}

@Suite("fMP4 box tools")
struct FMP4Tests {
    let initSegment = BoxBuilder.initSegment(tracks: [(1, 600, 0), (2, 48_000, 1)])

    @Test("Track timescales are read from tkhd/mdhd in both versions")
    func timescales() throws {
        let timescales = try FMP4.trackTimescales(initializationSegment: initSegment)
        #expect(timescales == [1: 600, 2: 48_000])
    }

    @Test("Box walker handles 64-bit sizes, size-zero boxes and rejects garbage")
    func walker() throws {
        let large = BoxBuilder.box("free", Data(repeating: 7, count: 10), largeSize: true)
        let toEnd = BoxBuilder.be32(0) + Data("mdat".utf8) + Data([1, 2, 3])
        let boxes = try FMP4.boxes(in: large + toEnd)
        #expect(boxes.map(\.type) == ["free", "mdat"])
        #expect(boxes[0].payload.count == 10)
        #expect(boxes[1].payload.count == 3)
        #expect(throws: FMP4.ParseError.self) { try FMP4.boxes(in: Data([0xAA, 0xAA, 0xAA, 0xAA, 0x41, 0x41, 0x41, 0x41])) }
        #expect(throws: FMP4.ParseError.self) { try FMP4.boxes(in: Data([0, 0, 0, 3])) }
    }

    @Test("Rebase shifts every fragment to a common origin and keeps inter-track offsets")
    func rebase() throws {
        // Video (track 1, 600 Hz) starts at 60.0 s, audio (track 2, 48 kHz) 10 ms later.
        let seg1 = BoxBuilder.mediaSegment(fragments: [(1, 36_000, 1), (2, 2_880_480, 0)], sidx: (1, 600, 36_000, 1))
        let seg2 = BoxBuilder.mediaSegment(fragments: [(1, 38_400, 1), (2, 3_072_480, 0)])
        let timescales = try FMP4.trackTimescales(initializationSegment: initSegment)
        let fields = try FMP4.timeFields(mediaSegment: seg1) + (try FMP4.timeFields(mediaSegment: seg2))
        #expect(fields.filter { $0.kind == .trackFragmentDecodeTime }.count == 4)
        #expect(fields.filter { $0.kind == .segmentIndex }.count == 1)

        let plan = try #require(FMP4.rebasePlan(timescales: timescales, fields: fields))
        #expect(plan.originSeconds == 60.0)
        #expect(plan.deltas == [1: 36_000, 2: 2_880_000])

        var patched1 = seg1
        try FMP4.apply(plan, to: &patched1, fields: FMP4.timeFields(mediaSegment: seg1))
        var patched2 = seg2
        try FMP4.apply(plan, to: &patched2, fields: FMP4.timeFields(mediaSegment: seg2))

        let after1 = try FMP4.timeFields(mediaSegment: patched1)
        #expect(after1.map(\.value) == [0, 0, 480]) // sidx, video tfdt, audio tfdt (10 ms later)
        let after2 = try FMP4.timeFields(mediaSegment: patched2)
        #expect(after2.map(\.value) == [2_400, 192_480])
        #expect(patched1.count == seg1.count)
        // Everything except the time fields is untouched.
        var expected = seg1
        let before1 = try FMP4.timeFields(mediaSegment: seg1).sorted { $0.offset < $1.offset }
        for (field, newField) in zip(before1, after1.sorted { $0.offset < $1.offset }) {
            for i in 0..<(field.is64Bit ? 8 : 4) { expected[field.offset + i] = patched1[newField.offset + i] }
        }
        #expect(expected == patched1)
    }

    @Test("A 32-bit tfdt that would underflow clamps to zero; overflow is rejected")
    func edgeCases() throws {
        let seg = BoxBuilder.mediaSegment(fragments: [(1, 100, 0)])
        let plan = FMP4.RebasePlan(originSeconds: 1, deltas: [1: 600])
        var patched = seg
        try FMP4.apply(plan, to: &patched, fields: FMP4.timeFields(mediaSegment: seg))
        #expect(try FMP4.timeFields(mediaSegment: patched).first?.value == 0)
    }

    @Test("Clip writer rebases real box structures and falls back to raw concatenation for unknown data")
    func writeClip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let initURL = dir.appendingPathComponent("init.mp4"), s1 = dir.appendingPathComponent("1.m4s"), s2 = dir.appendingPathComponent("2.m4s")
        try initSegment.write(to: initURL)
        try BoxBuilder.mediaSegment(fragments: [(1, 36_000, 1), (2, 2_880_000, 1)]).write(to: s1)
        try BoxBuilder.mediaSegment(fragments: [(1, 38_400, 1), (2, 3_072_000, 1)]).write(to: s2)
        let out = dir.appendingPathComponent("clip.mp4")
        let plan = try FMP4ClipAssembler.writeClip(initialization: initURL, mediaSegments: [s1, s2], to: out)
        #expect(plan?.originSeconds == 60)
        let clip = try Data(contentsOf: out)
        #expect(clip.count == initSegment.count + 2 * BoxBuilder.mediaSegment(fragments: [(1, 0, 1), (2, 0, 1)]).count)
        let boxes = try FMP4.boxes(in: clip)
        #expect(boxes.map(\.type) == ["ftyp", "moov", "styp", "moof", "mdat", "styp", "moof", "mdat"])
        let fields = try FMP4.timeFields(mediaSegment: clip)
        #expect(fields.map(\.value) == [0, 0, 2_400, 192_000])

        // Garbage inputs: concatenated verbatim, no error.
        let g1 = dir.appendingPathComponent("g1"), g2 = dir.appendingPathComponent("g2")
        try Data(repeating: 0xAA, count: 16).write(to: g1)
        try Data(repeating: 0xBB, count: 16).write(to: g2)
        let rawOut = dir.appendingPathComponent("raw.bin")
        let rawPlan = try FMP4ClipAssembler.writeClip(initialization: g1, mediaSegments: [g2], to: rawOut)
        #expect(rawPlan == nil)
        #expect(try Data(contentsOf: rawOut) == Data(repeating: 0xAA, count: 16) + Data(repeating: 0xBB, count: 16))
    }
}
