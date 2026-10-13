import Foundation
import zlib

/// Read-only classic TIFF decoder. All allocation and file offsets are bounded before use.
/// One reader belongs to one processing task; immutable metadata can cross actor boundaries.
final class TIFFReader {
    struct Tag { let type: Int; let count: Int; let bytes: Data }
    let handle: FileHandle
    let fileSize: UInt64
    let littleEndian: Bool
    private(set) var tags: [Int: Tag] = [:]
    private(set) var width = 0, height = 0
    private var bits = 0, format = 0, compression = 1, predictor = 1
    private var blockWidth = 0, blockHeight = 0
    private var offsets: [Int] = [], counts: [Int] = []
    private var cache: [Int: Data] = [:]
    private var cacheBytes = 0

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8, header.prefix(2) == Data([73,73]) || header.prefix(2) == Data([77,77]) else { throw TerrainError("This file is not a TIFF.") }
        littleEndian = header[0] == 73
        guard integer(header, 2, 2) == 42 else { throw TerrainError("BigTIFF is not supported by this reader. A native GDAL reader is needed for this file.") }
        let ifd = integer(header, 4, 4)
        let entryCount = Int(integer(try read(ifd, 2), 0, 2))
        guard entryCount <= 4096 else { throw TerrainError("TIFF metadata exceeds the supported limit.") }
        let entries = try read(ifd + 2, entryCount * 12)
        let sizes = [1:1, 2:1, 3:2, 4:4, 5:8, 6:1, 7:1, 8:2, 9:4, 10:8, 11:4, 12:8]
        for i in 0..<entryCount {
            let p = i*12, id = Int(integer(entries,p,2)), type = Int(integer(entries,p+2,2)), count = Int(integer(entries,p+4,4))
            guard let size = sizes[type] else { continue }
            guard count <= 2_000_000, count * size <= 16_000_000 else { throw TerrainError("TIFF metadata is too large.") }
            let bytes = count * size <= 4 ? Data(entries[(p+8)..<(p+8+count*size)]) : try read(integer(entries,p+8,4), count*size)
            guard tags[id] == nil else { throw TerrainError("TIFF contains duplicate metadata tags.") }
            tags[id] = Tag(type: type, count: count, bytes: bytes)
        }
        guard tags[330] == nil, tags[338] == nil else {
            throw TerrainError("SubIFD or extra-sample masks require a GDAL-backed reader.")
        }
        guard try scalar(254, fallback: 0) == 0 else { throw TerrainError("The first TIFF image is not a full-resolution elevation raster.") }
        // Reject internal validity masks instead of treating masked samples as elevations.
        var nextIFD = integer(try read(ifd + 2 + UInt64(entryCount*12), 4),0,4)
        var visited: Set<UInt64> = [ifd]
        while nextIFD != 0 {
            guard visited.count < 64, visited.insert(nextIFD).inserted else { throw TerrainError("TIFF has a cyclic or excessive image directory chain.") }
            let count = Int(integer(try read(nextIFD,2),0,2))
            guard count <= 4096 else { throw TerrainError("TIFF image directory exceeds limits.") }
            let directory = try read(nextIFD+2,count*12)
            var subfileType = 0
            for i in 0..<count {
                let p = i*12, tag = integer(directory,p,2)
                if tag == 254 {
                    guard integer(directory,p+2,2) == 4, integer(directory,p+4,4) == 1 else { throw TerrainError("Invalid TIFF subfile type.") }
                    subfileType = Int(integer(directory,p+8,4))
                }
                if tag == 330 { throw TerrainError("Nested TIFF image masks require GDAL.") }
            }
            guard subfileType == 1 else { throw TerrainError("Additional TIFF images or internal masks require a GDAL-backed reader.") }
            nextIFD = integer(try read(nextIFD+2+UInt64(count*12),4),0,4)
        }
        width = try scalar(256); height = try scalar(257)
        guard width >= 2, height >= 2, width <= 200_000, height <= 200_000 else { throw TerrainError("Unsupported raster dimensions.") }
        bits = try scalar(258); format = try scalar(339, fallback: 1)
        compression = try scalar(259, fallback: 1); predictor = try scalar(317, fallback: 1)
        guard try scalar(277, fallback: 1) == 1, try scalar(284, fallback: 1) == 1,
              try scalar(274, fallback: 1) == 1, try scalar(266, fallback: 1) == 1,
              try scalar(262, fallback: 1) == 1 else { throw TerrainError("Use a single-band, top-left-oriented grayscale elevation TIFF.") }
        guard (format == 3 && [32,64].contains(bits)) || ([1,2].contains(format) && [16,32].contains(bits)) else { throw TerrainError("Supported elevation samples are Float32/64 or signed/unsigned 16/32-bit integers.") }
        guard [1,5,8,32946].contains(compression) else { throw TerrainError("Unsupported TIFF compression \(compression). This reader supports uncompressed, LZW, and Deflate TIFFs.") }
        guard predictor == 1 || (predictor == 2 && format != 3) || (predictor == 3 && format == 3) else { throw TerrainError("Unsupported TIFF predictor for the elevation sample type.") }
        if tags[324] != nil {
            blockWidth = try scalar(322); blockHeight = try scalar(323)
            offsets = try integers(324); counts = try integers(325)
        } else {
            blockWidth = width; blockHeight = min(height, try scalar(278, fallback: height))
            offsets = try integers(273); counts = try integers(279)
        }
        guard blockWidth > 0, blockHeight > 0, blockWidth <= 200_000, blockHeight <= 200_000,
              blockWidth * blockHeight <= 16_000_000 / (bits/8) else { throw TerrainError("TIFF strips/tiles exceed the 16 MB block memory limit. Use a tiled source or smaller strips.") }
        let expected = ((width + blockWidth - 1) / blockWidth) * ((height + blockHeight - 1) / blockHeight)
        guard offsets.count == expected, counts.count == expected else { throw TerrainError("TIFF block directory is incomplete.") }
        for i in offsets.indices {
            guard counts[i] > 0, counts[i] <= 32_000_000, UInt64(offsets[i]) <= fileSize,
                  UInt64(counts[i]) <= fileSize - UInt64(offsets[i]) else { throw TerrainError("TIFF block points outside the file or exceeds memory limits.") }
        }
    }
    deinit { try? handle.close() }
    func integer(_ data: Data, _ start: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for k in 0..<count { value |= UInt64(data[start+k]) << (8 * (littleEndian ? k : count-1-k)) }
        return value
    }
    private func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard offset <= fileSize, count >= 0, UInt64(count) <= fileSize - offset else { throw TerrainError("TIFF is truncated or contains an invalid offset.") }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw TerrainError("Unable to read TIFF data.") }
        return data
    }
    func integers(_ id: Int) throws -> [Int] {
        guard let t = tags[id], [1,3,4].contains(t.type) else { throw TerrainError("TIFF tag \(id) is missing or has an invalid type.") }
        let size = t.type == 4 ? 4 : (t.type == 3 ? 2 : 1)
        return (0..<t.count).map { Int(integer(t.bytes,$0*size,size)) }
    }
    func scalar(_ id: Int, fallback: Int? = nil) throws -> Int {
        if tags[id] == nil, let fallback { return fallback }
        let values = try integers(id)
        guard values.count == 1 else { throw TerrainError("TIFF tag \(id) must contain one value.") }
        return values[0]
    }
    func doubles(_ id: Int) throws -> [Double]? {
        guard let t = tags[id] else { return nil }
        guard t.type == 12 else { throw TerrainError("Invalid floating-point metadata tag \(id).") }
        return (0..<t.count).map { Double(bitPattern: integer(t.bytes,$0*8,8)) }
    }
    func string(_ id: Int) -> String? {
        guard let t = tags[id], t.type == 2 else { return nil }
        return String(data: t.bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }
    private func block(_ index: Int) throws -> Data {
        if let data = cache[index] { return data }
        try Task.checkCancellation()
        let source = try read(UInt64(offsets[index]), counts[index])
        let across = (width + blockWidth - 1) / blockWidth
        let rows = tags[324] == nil ? min(blockHeight, height - index/across * blockHeight) : blockHeight
        let expected = blockWidth * rows * (bits/8)
        var data: Data
        switch compression {
        case 1: data = source
        case 5: data = try Self.decodeLZW(source, expected: expected)
        default:
            var target = Data(count: expected), length = uLongf(expected)
            let status = target.withUnsafeMutableBytes { dst in
                source.withUnsafeBytes { src in
                    uncompress(dst.bindMemory(to: Bytef.self).baseAddress!, &length, src.bindMemory(to: Bytef.self).baseAddress!, uLong(source.count))
                }
            }
            guard status == Z_OK, length == expected else { throw TerrainError("Invalid Deflate-compressed TIFF block.") }
            data = target
        }
        guard data.count == expected else { throw TerrainError("Decoded TIFF block has the wrong size.") }
        let stride = bits/8, rowBytes = blockWidth * stride
        if predictor == 2 {
            let mask: UInt64 = bits == 32 ? 0xffffffff : 0xffff
            for row in 0..<rows {
                for x in 1..<blockWidth {
                    let p = row*rowBytes+x*stride
                    let v = (integer(data,p,stride) + integer(data,p-stride,stride)) & mask
                    for k in 0..<stride { data[p+k] = UInt8((v >> (8*(littleEndian ? k : stride-1-k))) & 255) }
                }
            }
        } else if predictor == 3 {
            // TIFF Technical Note 3: byte planes are most-significant first, regardless of byte order.
            for row in 0..<rows {
                let offset = row*rowBytes
                for i in 1..<rowBytes { data[offset+i] = data[offset+i] &+ data[offset+i-1] }
                let shuffled = Array(data[offset..<(offset+rowBytes)])
                for x in 0..<blockWidth {
                    for k in 0..<stride { data[offset+x*stride+k] = shuffled[(littleEndian ? stride-1-k : k)*blockWidth+x] }
                }
            }
        }
        if cacheBytes + data.count > 24_000_000 { cache.removeAll(keepingCapacity: true); cacheBytes = 0 }
        cache[index] = data; cacheBytes += data.count
        return data
    }
    func sample(column: Int, row: Int) throws -> Double {
        guard column >= 0, row >= 0, column < width, row < height else { throw TerrainError("Requested sample is outside the DEM.") }
        let index = row/blockHeight * ((width+blockWidth-1)/blockWidth) + column/blockWidth
        let data = try block(index), stride = bits/8
        let p = ((row % blockHeight)*blockWidth + column % blockWidth)*stride
        let raw = integer(data,p,stride)
        if format == 3 { return bits == 32 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw) }
        if format == 2 { return bits == 16 ? Double(Int16(bitPattern: UInt16(raw))) : Double(Int32(bitPattern: UInt32(raw))) }
        return Double(raw)
    }
    static func decodeLZW(_ input: Data, expected: Int) throws -> Data {
        var bit = 0, width = 9, next = 258
        var table = (0..<256).map { [UInt8($0)] } + Array(repeating: [UInt8](), count: 3840)
        var previous: [UInt8]? = nil, output = Data()
        var sawEnd = false, sawClear = false
        while bit + width <= input.count*8 {
            var code = 0
            for _ in 0..<width { code = (code << 1) | Int((input[bit/8] >> (7-bit%8)) & 1); bit += 1 }
            if code == 256 { width = 9; next = 258; previous = nil; sawClear = true; continue }
            if code == 257 { sawEnd = true; break }
            guard sawClear else { throw TerrainError("TIFF LZW stream is missing a clear code.") }
            let entry: [UInt8]
            if code < next, !table[code].isEmpty { entry = table[code] }
            else if code == next, let previous, let first = previous.first { entry = previous + [first] }
            else { throw TerrainError("Invalid TIFF LZW code.") }
            guard output.count + entry.count <= expected else { throw TerrainError("TIFF LZW output exceeds the declared block size.") }
            output.append(contentsOf: entry)
            if let previous, let first = entry.first, next < 4096 {
                table[next] = previous + [first]; next += 1
                if next == (1 << width) - 1 && width < 12 { width += 1 }
            }
            previous = entry
        }
        guard sawEnd, output.count == expected else { throw TerrainError("Truncated TIFF LZW block.") }
        return output
    }
}
