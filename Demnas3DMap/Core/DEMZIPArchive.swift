import Foundation
import zlib

/// Bounded reader for ordinary ZIP archives containing one DEM GeoTIFF.
/// Only the TIFF and same-named georeferencing companions are extracted.
enum DEMZIPArchive {
    private struct Entry {
        let name: String
        let method: Int
        let flags: Int
        let crc: UInt32
        let compressed: Int
        let uncompressed: Int
        let localOffset: Int
    }

    private static func u16(_ bytes: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { throw TerrainError("ZIP terpotong.") }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { throw TerrainError("ZIP terpotong.") }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    static func extract(url: URL, into directory: URL) throws -> [URL] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard fileSize <= 256_000_000 else { throw TerrainError("ZIP DEM lebih besar dari batas impor 256 MB.") }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 22 else { throw TerrainError("File ZIP tidak lengkap.") }
        let searchStart = max(0, bytes.count - 65_557)
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: searchStart, by: -1) {
            if (try? u32(bytes, offset)) == 0x06054b50,
               let comment = try? u16(bytes, offset + 20), offset + 22 + comment == bytes.count {
                end = offset
                break
            }
        }
        guard let end, try u16(bytes, end + 4) == 0, try u16(bytes, end + 6) == 0 else {
            throw TerrainError("ZIP tidak valid atau terdiri dari beberapa bagian.")
        }
        let count = try u16(bytes, end + 10)
        let centralSize = try u32(bytes, end + 12)
        let centralOffset = try u32(bytes, end + 16)
        guard count > 0, count <= 64, centralSize <= 1_000_000,
              centralOffset <= bytes.count, centralSize <= bytes.count - centralOffset,
              try u16(bytes, end + 8) == count else {
            throw TerrainError("Daftar file ZIP terlalu besar atau format ZIP64 belum didukung.")
        }
        var entries = [Entry]()
        var cursor = centralOffset
        for _ in 0..<count {
            guard try u32(bytes, cursor) == 0x02014b50 else { throw TerrainError("Daftar file ZIP rusak.") }
            let flags = try u16(bytes, cursor + 8)
            let method = try u16(bytes, cursor + 10)
            let crc = UInt32(try u32(bytes, cursor + 16))
            let compressed = try u32(bytes, cursor + 20)
            let uncompressed = try u32(bytes, cursor + 24)
            let nameLength = try u16(bytes, cursor + 28)
            let extraLength = try u16(bytes, cursor + 30)
            let commentLength = try u16(bytes, cursor + 32)
            let offset = try u32(bytes, cursor + 42)
            guard compressed != 0xffff_ffff, uncompressed != 0xffff_ffff,
                  offset != 0xffff_ffff, nameLength > 0,
                  cursor + 46 + nameLength + extraLength + commentLength <= centralOffset + centralSize,
                  let name = String(data: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else {
                throw TerrainError("ZIP64 atau nama file ZIP tidak didukung.")
            }
            entries.append(.init(name: name, method: method, flags: flags, crc: crc,
                                 compressed: compressed, uncompressed: uncompressed, localOffset: offset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == centralOffset + centralSize else { throw TerrainError("Daftar file ZIP tidak konsisten.") }
        let rasters = entries.filter { entry in
            let path = entry.name.replacingOccurrences(of: "\\", with: "/")
            let file = URL(fileURLWithPath: path)
            guard !path.split(separator: "/").contains(where: { $0 == "__MACOSX" }),
                  !file.lastPathComponent.hasPrefix("._") else { return false }
            return ["tif", "tiff"].contains(file.pathExtension.lowercased())
        }
        guard rasters.count == 1, let raster = rasters.first else {
            throw TerrainError("ZIP harus berisi tepat satu GeoTIFF .tif/.tiff. Ekstrak ZIP secara manual jika ada beberapa DEM.")
        }
        let tifName = URL(fileURLWithPath: raster.name).lastPathComponent.lowercased()
        let tifFolder = URL(fileURLWithPath: raster.name).deletingLastPathComponent().path.lowercased()
        let base = URL(fileURLWithPath: tifName).deletingPathExtension().lastPathComponent
        let accepted = Set([tifName, base + ".tfw", base + ".tifw", base + ".wld",
                            base + ".prj", tifName + ".aux.xml"])
        let selected = entries.filter {
            let file = URL(fileURLWithPath: $0.name)
            return file.deletingLastPathComponent().path.lowercased() == tifFolder &&
                accepted.contains(file.lastPathComponent.lowercased())
        }
        guard selected.count <= 6 else { throw TerrainError("ZIP memiliki metadata DEM duplikat.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var extracted = [URL]()
        for entry in selected {
            try Task.checkCancellation()
            let name = URL(fileURLWithPath: entry.name).lastPathComponent.lowercased()
            let destination = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path), entry.flags & 1 == 0,
                  [0, 8].contains(entry.method), entry.uncompressed <= (name == tifName ? 2_000_000_000 : 1_000_000) else {
                throw TerrainError("ZIP terenkripsi, memiliki file duplikat, atau melebihi batas ukuran DEM.")
            }
            try extract(entry, from: bytes, to: destination)
            extracted.append(destination)
        }
        return extracted
    }

    private static func extract(_ entry: Entry, from bytes: Data, to destination: URL) throws {
        let offset = entry.localOffset
        guard try u32(bytes, offset) == 0x04034b50,
              try u16(bytes, offset + 8) == entry.method else { throw TerrainError("Header file ZIP tidak cocok.") }
        let dataStart = offset + 30 + (try u16(bytes, offset + 26)) + (try u16(bytes, offset + 28))
        guard dataStart <= bytes.count, entry.compressed <= bytes.count - dataStart else {
            throw TerrainError("Data file ZIP terpotong.")
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var checksum = crc32(0, nil, 0)
        var written = 0
        if entry.method == 0 {
            guard entry.compressed == entry.uncompressed else { throw TerrainError("Ukuran file ZIP tidak cocok.") }
            for start in stride(from: dataStart, to: dataStart + entry.compressed, by: 65_536) {
                try Task.checkCancellation()
                let end = min(start + 65_536, dataStart + entry.compressed)
                let chunk = Data(bytes[start..<end])
                try output.write(contentsOf: chunk)
                chunk.withUnsafeBytes { raw in
                    checksum = crc32(checksum, raw.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count))
                }
                written += chunk.count
            }
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw TerrainError("Dekompresi ZIP tidak dapat dimulai.")
            }
            defer { inflateEnd(&stream) }
            try bytes.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { throw TerrainError("ZIP kosong.") }
                stream.next_in = UnsafeMutablePointer(mutating: base.advanced(by: dataStart))
                stream.avail_in = uInt(entry.compressed)
                var result = Int32(Z_OK)
                repeat {
                    try Task.checkCancellation()
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    let capacity = buffer.count
                    let produced = buffer.withUnsafeMutableBytes { outputBytes -> Int in
                        stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(capacity)
                        result = inflate(&stream, Z_NO_FLUSH)
                        return capacity - Int(stream.avail_out)
                    }
                    guard result == Z_OK || result == Z_STREAM_END else { throw TerrainError("Data terkompresi ZIP rusak.") }
                    guard written + produced <= entry.uncompressed else { throw TerrainError("Isi ZIP melebihi ukuran yang dinyatakan.") }
                    if produced > 0 {
                        let chunk = Data(buffer.prefix(produced))
                        try output.write(contentsOf: chunk)
                        chunk.withUnsafeBytes { part in
                            checksum = crc32(checksum, part.bindMemory(to: Bytef.self).baseAddress, uInt(produced))
                        }
                        written += produced
                    }
                    if result == Z_OK && produced == 0 && stream.avail_in == 0 {
                        throw TerrainError("Data ZIP terpotong sebelum dekompresi selesai.")
                    }
                } while result != Z_STREAM_END
                guard stream.total_in == entry.compressed else { throw TerrainError("Panjang data ZIP tidak cocok.") }
            }
        }
        guard written == entry.uncompressed, UInt32(checksum) == entry.crc else {
            throw TerrainError("Ukuran atau checksum file ZIP tidak cocok.")
        }
    }
}
