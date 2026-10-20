import Testing
import Foundation
import CoreLocation
import zlib
@testable import TerrainCore

private struct Fixture {
    var width = 6, height = 6
    var epsg: Int? = 4326
    var transform = true
    var pointPixels = false
    var bigEndian = false
    var compression = 1
    var predictor = 1
    var tiled = false
    var bits = 32
    var sampleFormat = 3
    var noData: Float?
    var values: [Float] = (0..<36).map { (index: Int) -> Float in
        let row = index / 6
        let column = index % 6
        return Float(100 + row * 10 + column)
    }
    var matrix: [Double]?
    var extra: [(Int,Int,Int,Data)] = []
    func bytes(_ value: UInt64,_ count:Int) -> Data {
        Data((0..<count).map { UInt8((value >> (8*(bigEndian ? count-1-$0 : $0))) & 255) })
    }
    func make() throws -> Data {
        func shorts(_ values:[Int]) -> Data { values.reduce(into:Data()) { $0.append(bytes(UInt64($1),2)) } }
        func doubles(_ values:[Double]) -> Data { values.reduce(into:Data()) { $0.append(bytes($1.bitPattern,8)) } }
        var raw = values.reduce(into:Data()) { output, sample in
            let raw: UInt64
            if sampleFormat == 3 { raw = bits == 64 ? Double(sample).bitPattern : UInt64(sample.bitPattern) }
            else if sampleFormat == 2 { raw = bits == 16 ? UInt64(UInt16(bitPattern:Int16(sample))) : UInt64(UInt32(bitPattern:Int32(sample))) }
            else { raw = UInt64(sample) }
            output.append(bytes(raw,bits/8))
        }
        if predictor == 3 {
            for row in 0..<height {
                let start = row*width*4, original = Array(raw[start..<(start+width*4)])
                var shuffled = [UInt8](repeating:0,count:width*4)
                for plane in 0..<4 { for x in 0..<width { shuffled[plane*width+x] = original[x*4+(bigEndian ? plane : 3-plane)] } }
                for i in stride(from:shuffled.count-1,through:1,by:-1) { shuffled[i] = shuffled[i] &- shuffled[i-1] }
                raw.replaceSubrange(start..<(start+width*4),with:shuffled)
            }
        }
        if compression == 8 {
            var size = compressBound(uLong(raw.count)), output = Data(count:Int(size))
            let status = output.withUnsafeMutableBytes { out in raw.withUnsafeBytes { src in
                compress2(out.bindMemory(to:Bytef.self).baseAddress!,&size,src.bindMemory(to:Bytef.self).baseAddress!,uLong(raw.count),6)
            } }
            #expect(status == Z_OK)
            raw = output.prefix(Int(size))
        } else if compression == 5 {
            // Literal-only LZW fixture; resets before width changes.
            var codes = [256]
            for (i,byte) in raw.enumerated() { if i > 0 && i%200 == 0 { codes.append(256) }; codes.append(Int(byte)) }
            codes.append(257)
            var packed = Data(repeating:0,count:(codes.count*9+7)/8), cursor = 0
            for code in codes { for shift in stride(from:8,through:0,by:-1) { packed[cursor/8] |= UInt8((code >> shift)&1) << (7-cursor%8); cursor += 1 } }
            raw = packed
        }
        var keys = [1,1,0,0,1024,0,1,epsg == 4326 || epsg == nil ? 2 : 1,1025,0,1,pointPixels ? 2 : 1,4096,0,1,3855,4099,0,1,9001]
        if let epsg { keys += [epsg == 4326 ? 2048 : 3072,0,1,epsg] }
        keys[3] = (keys.count-4)/4
        var tags: [(Int,Int,Int,Data)] = [
            (256,4,1,bytes(UInt64(width),4)),(257,4,1,bytes(UInt64(height),4)),(258,3,1,shorts([bits])),
            (259,3,1,shorts([compression])),(262,3,1,shorts([1])),(277,3,1,shorts([1])),
            (317,3,1,shorts([predictor])),(339,3,1,shorts([sampleFormat])),(34735,3,keys.count,shorts(keys))
        ]
        if tiled { tags += [(322,4,1,bytes(UInt64(width),4)),(323,4,1,bytes(UInt64(height),4)),(324,4,1,Data(count:4)),(325,4,1,bytes(UInt64(raw.count),4))] }
        else { tags += [(273,4,1,Data(count:4)),(278,4,1,bytes(UInt64(height),4)),(279,4,1,bytes(UInt64(raw.count),4))] }
        if let matrix { tags.append((34264,12,matrix.count,doubles(matrix))) }
        else if transform { tags += [(33550,12,3,doubles([0.001,0.001,0])),(33922,12,6,doubles([0,0,0,110,-7,0]))] }
        if let noData { let text = Data("\(noData)\0".utf8); tags.append((42113,2,text.count,text)) }
        tags += extra
        tags.sort { $0.0 < $1.0 }
        let dataStart = 8+2+tags.count*12+4
        var extras = Data(), entries = Data()
        for (id,type,count,data) in tags {
            entries.append(bytes(UInt64(id),2)); entries.append(bytes(UInt64(type),2)); entries.append(bytes(UInt64(count),4))
            if id == 273 || id == 324 { entries.append(Data(count:4)) }
            else if data.count <= 4 { entries.append(data); entries.append(Data(count:4-data.count)) }
            else { entries.append(bytes(UInt64(dataStart+extras.count),4)); extras.append(data) }
        }
        let offsetTag = tags.firstIndex { $0.0 == 273 || $0.0 == 324 }!
        entries.replaceSubrange((offsetTag*12+8)..<(offsetTag*12+12),with:bytes(UInt64(dataStart+extras.count),4))
        return Data(bigEndian ? [77,77] : [73,73]) + bytes(42,2) + bytes(8,4) + bytes(UInt64(tags.count),2) + entries + Data(count:4) + extras + raw
    }
    func withFile<T>(_ body:(URL)throws->T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("dem.tif")
        try make().write(to:url)
        return try body(url)
    }
}

private func geo(_ pixel:Point2) -> GeoPoint { .init(longitude:110+pixel.x*0.001,latitude:-7-pixel.y*0.001) }
private let boundary = [Point2(x:1,y:1),Point2(x:4.8,y:1.2),Point2(x:4.1,y:4.6),Point2(x:1.2,y:4.2)]

@Test func mapCoordinateCaptureAndPolygonValidation() throws {
    var selection = PolygonSelectionModel()
    for p in boundary { try selection.add(geo(p).coordinate) }
    #expect(selection.coordinates[0].latitude == geo(boundary[0]).latitude)
    #expect(selection.coordinates[1].longitude == geo(boundary[1]).longitude)
    try selection.finish(); #expect(selection.isFinished)
    selection.undo(); #expect(!selection.isFinished && selection.coordinates.count == 3)
    selection.reset(); #expect(selection.coordinates.isEmpty)
    #expect(throws:TerrainError.self) { try selection.add(.init(latitude:91,longitude:0)) }
    #expect(throws:TerrainError.self) { try Geometry.validate([.init(x:0,y:0),.init(x:1,y:1),.init(x:0,y:1),.init(x:1,y:0)]) }
    #expect(throws:TerrainError.self) { try Geometry.validate([.init(x:0,y:0),.init(x:1,y:0),.init(x:0,y:0)]) }
}

@Test func demnasImageServerRequestPadsAndBoundsTheSelectedPolygon() throws {
    let polygon = [
        GeoPoint(longitude: 110.4300, latitude: -7.7600),
        GeoPoint(longitude: 110.4400, latitude: -7.7600),
        GeoPoint(longitude: 110.4400, latitude: -7.7500),
        GeoPoint(longitude: 110.4300, latitude: -7.7500)
    ]
    let export = try DEMNASImageServer.request(for: polygon)
    #expect(export.width > 4 && export.height > 4)
    #expect(export.width <= 2_000 && export.height <= 2_000)
    #expect(export.bounds.west < 110.4300 && export.bounds.east > 110.4400)
    #expect(export.bounds.south < -7.7600 && export.bounds.north > -7.7500)
    let items = try #require(URLComponents(url: export.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.first(where: { $0.name == "format" })?.value == "tiff")
    #expect(items.first(where: { $0.name == "pixelType" })?.value == "F32")
    #expect(items.first(where: { $0.name == "adjustAspectRatio" })?.value == "false")
    #expect(items.first(where: { $0.name == "f" })?.value == "image")

    let pixelWidth = (export.bounds.east - export.bounds.west) / Double(export.width)
    #expect(pixelWidth >= 0.0001999)

    let transform = AffineTransform(x0: export.bounds.west,
                                    a: (export.bounds.east - export.bounds.west) / Double(export.width), b: 0,
                                    y0: export.bounds.north, d: 0,
                                    e: -(export.bounds.north - export.bounds.south) / Double(export.height))
    for point in polygon {
        let pixel = transform.pixel(point.point)
        #expect(pixel.x > 0.5 && pixel.x < Double(export.width) - 0.5)
        #expect(pixel.y > 0.5 && pixel.y < Double(export.height) - 0.5)
    }
}

@Test func demnasImageServerRejectsSelectionOutsideCoverage() throws {
    let outside = [
        GeoPoint(longitude: 94.75001, latitude: -7.00),
        GeoPoint(longitude: 94.75100, latitude: -7.00),
        GeoPoint(longitude: 94.75100, latitude: -6.99),
        GeoPoint(longitude: 94.75001, latitude: -6.99)
    ]
    #expect(throws: TerrainError.self) { try DEMNASImageServer.request(for: outside) }
}

@Test(arguments:[false,true]) func geotiffMetadataAndEndian(bigEndian:Bool) throws {
    var fixture = Fixture(); fixture.bigEndian = bigEndian
    try fixture.withFile { url in
        let source = try GeoTIFFSource(url:url,confirmedDEMNAS:false)
        #expect(source.metadata.width == 6 && source.metadata.epsg == 4326)
        #expect(abs(source.metadata.footprint[0].longitude-110) < 1e-10)
        #expect(abs(source.metadata.footprint[0].latitude+7) < 1e-10)
        #expect(try source.sample(column:2,row:3) == 132)
        let pixel = source.metadata.transform.pixel(.init(x:110.0025,y:-7.0035))
        #expect(abs(pixel.x-2.5) < 1e-8 && abs(pixel.y-3.5) < 1e-8)
    }
}

@Test(arguments:[1,5,8], [false,true]) func compressionAndFloatingPredictor(compression:Int,bigEndian:Bool) throws {
    for predictor in [1,3] {
        var fixture = Fixture(); fixture.compression = compression; fixture.predictor = predictor; fixture.bigEndian = bigEndian
        fixture.tiled = true
        fixture.values[4] = -12.625
        try fixture.withFile { url in
            let reader = try TIFFReader(url:url)
            for y in 0..<6 { for x in 0..<6 { #expect(try reader.sample(column:x,row:y) == Double(fixture.values[y*6+x])) } }
        }
    }
}

@Test func pixelIsPointAndRotatedAffine() throws {
    var fixture = Fixture(); fixture.pointPixels = true
    try fixture.withFile { url in
        let source = try GeoTIFFSource(url:url,confirmedDEMNAS:false)
        let center = source.metadata.transform.world(.init(x:0.5,y:0.5))
        #expect(abs(center.x-110) < 1e-10 && abs(center.y+7) < 1e-10)
    }
    fixture.pointPixels = false; fixture.transform = false
    fixture.matrix = [0.001,0.0002,0,110,0.0001,-0.001,0,-7,0,0,1,0,0,0,0,1]
    try fixture.withFile { url in
        let source = try GeoTIFFSource(url:url,confirmedDEMNAS:false)
        let p = Point2(x:2.4,y:3.2), result = source.metadata.transform.pixel(source.metadata.transform.world(p))
        #expect((result-p).length < 1e-8)
    }
}

@Test func crsKnownControlPointsAndRoundTrips() throws {
    let mercator = try CoordinateTransformer(epsg:3857)
    let p = try mercator.project(.init(longitude:180,latitude:0))
    #expect(abs(p.x-20037508.342789244) < 1e-6 && abs(p.y) < 1e-6)
    for code in [4326,3857,32649,32749] {
        let crs = try CoordinateTransformer(epsg:code)
        let geo = GeoPoint(longitude:110.4,latitude:code == 32649 ? 7.5 : -7.5)
        let restored = try crs.unproject(crs.project(geo))
        #expect(abs(restored.longitude-geo.longitude) < 1e-7 && abs(restored.latitude-geo.latitude) < 1e-7)
    }
    let utm = try CoordinateTransformer(epsg:32749)
    let equator = try utm.project(.init(longitude:111,latitude:0))
    #expect(abs(equator.x-500000) < 1e-6 && abs(equator.y-10000000) < 1e-6)
    #expect(throws:TerrainError.self) { try CoordinateTransformer(epsg:23836) }
}

@Test func missingMetadataRecoveryAndConflicts() throws {
    var fixture = Fixture(); fixture.epsg = nil
    try fixture.withFile { url in
        #expect(throws:TerrainError.self) { try GeoTIFFSource(url:url,confirmedDEMNAS:true) }
        try "EPSG:4326".write(to:url.deletingPathExtension().appendingPathExtension("prj"),atomically:true,encoding:.utf8)
        #expect(try GeoTIFFSource(url:url,confirmedDEMNAS:false).metadata.epsg == 4326)
    }
    fixture.transform = false
    try fixture.withFile { url in
        try "EPSG:4326".write(to:url.deletingPathExtension().appendingPathExtension("prj"),atomically:true,encoding:.utf8)
        #expect(throws:TerrainError.self) { try GeoTIFFSource(url:url,confirmedDEMNAS:true) }
        try "0.001\n0\n0\n-0.001\n110.0005\n-7.0005".write(to:url.deletingPathExtension().appendingPathExtension("tfw"),atomically:true,encoding:.utf8)
        let source = try GeoTIFFSource(url:url,confirmedDEMNAS:false)
        #expect(abs(source.metadata.transform.x0-110) < 1e-10)
    }
    try Fixture().withFile { url in
        try "EPSG:3857".write(to:url.deletingPathExtension().appendingPathExtension("prj"),atomically:true,encoding:.utf8)
        #expect(throws:TerrainError.self) { try GeoTIFFSource(url:url,confirmedDEMNAS:false) }
    }
    #expect(throws:TerrainError.self) { try CompanionMetadata.explicitEPSG(in:#"PROJCS["Unknown",GEOGCS["WGS84",AUTHORITY["EPSG","4326"]]]"#) }
    #expect(try CompanionMetadata.explicitEPSG(in:#"GEOGCS["WGS84",AUTHORITY["EPSG","4326"]]"#) == 4326)
}

@Test func clippingPreservesSamplesAndExactConcaveMeshBoundary() throws {
    let concave = [Point2(x:0.8,y:0.9),Point2(x:5.1,y:1),Point2(x:5,y:2.3),Point2(x:2.7,y:2.3),Point2(x:2.7,y:5),Point2(x:0.9,y:5)]
    try Fixture().withFile { url in
        let source = try GeoTIFFSource(url:url,confirmedDEMNAS:false)
        let grid = try RasterClippingService.clip(source:source,polygon:concave.map(geo))
        #expect(grid.elevations[0] == 100)
        #expect(grid.mask.contains(false) && grid.mask.contains(true))
        let mesh = try TerrainMeshGenerator.generate(grid)
        var pixelArea = 0.0
        for i in stride(from:0,to:mesh.indices.count,by:3) {
            let points = (0..<3).map { j in source.metadata.transform.pixel(mesh.geographicVertices[Int(mesh.indices[i+j])].point) }
            pixelArea += abs(Geometry.area(points))
            #expect(Geometry.contains(points.reduce(.init(x:0,y:0),+)*(1.0/3),in:concave))
        }
        #expect(abs(pixelArea-abs(Geometry.area(concave))) < 1e-6)
        for (index,coordinate) in mesh.geographicVertices.enumerated() {
            let pixel = source.metadata.transform.pixel(coordinate.point)
            let expected = 100+(pixel.x-0.5)+10*(pixel.y-0.5)
            #expect(abs(mesh.elevations[index]-expected) < 1e-6)
            #expect(abs(Double(mesh.positions[index].y)-(expected-mesh.elevationOrigin)) < 1e-4)
            #expect(mesh.normals[index].y > 0)
        }
    }
}

@Test func coverageNoDataAndDownsamplingSafety() throws {
    var fixture = Fixture(); fixture.noData = -9999; fixture.values[2*6+2] = -9999
    try fixture.withFile { url in
        let source = try GeoTIFFSource(url:url,confirmedDEMNAS:false)
        // The missing source sample must still be found when rendering with only two samples per axis.
        #expect(throws:TerrainError.self) { try RasterClippingService.clip(source:source,polygon:boundary.map(geo),maxAxis:2) }
    }
    try Fixture().withFile { url in
        let source = try GeoTIFFSource(url:url,confirmedDEMNAS:false)
        let outside = [Point2(x:1,y:1),Point2(x:7,y:1),Point2(x:1,y:4)]
        #expect(throws:TerrainError.self) { try RasterClippingService.clip(source:source,polygon:outside.map(geo)) }
        let grid = try RasterClippingService.clip(source:source,polygon:boundary.map(geo),maxAxis:2)
        let mesh = try TerrainMeshGenerator.generate(grid)
        #expect(grid.columns.count == 2 && mesh.indices.count > 0)
        #expect(mesh.minimum >= 100 && mesh.maximum <= 155)
    }
}

@Test func extremeImageServerSentinelIsRejectedAsInvalidElevation() throws {
    var fixture = Fixture()
    fixture.values[2 * fixture.width + 2] = 1.1342745e38
    try fixture.withFile { url in
        let source = try GeoTIFFSource(url: url, confirmedDEMNAS: false)
        #expect(throws: TerrainError.self) { try RasterClippingService.clip(source: source, polygon: boundary.map(geo)) }
    }
}

@Test func malformedTIFFRejected() throws {
    try Fixture().withFile { url in
        let original = try Data(contentsOf:url)
        for count in [0,2,8,24,original.count-4] {
            try original.prefix(count).write(to:url)
            #expect(throws:(any Error).self) { try TIFFReader(url:url) }
        }
    }
    #expect(throws:TerrainError.self) { try TIFFReader.decodeLZW(Data([0,0]),expected:4) }
    let singular = AffineTransform(x0:0,a:0,b:0,y0:0,d:0,e:0)
    #expect(throws:TerrainError.self) { try singular.validate() }
}

@Test func auxiliaryXMLRecoveryAndScaleSafety() throws {
    var fixture = Fixture(); fixture.epsg = nil; fixture.transform = false
    try fixture.withFile { url in
        let xml = "<PAMDataset><SRS>EPSG:4326</SRS><GeoTransform>110,0.001,0,-7,0,-0.001</GeoTransform><PAMRasterBand band=\"1\"><NoDataValue>-9999</NoDataValue></PAMRasterBand></PAMDataset>"
        try xml.write(to:url.appendingPathExtension("aux.xml"),atomically:true,encoding:.utf8)
        let metadata = try GeoTIFFSource(url:url,confirmedDEMNAS:false).metadata
        #expect(metadata.epsg == 4326 && metadata.noData == -9999)
        #expect(metadata.transform.x0 == 110)
    }
    for (xml,accepted) in [("<GDALMetadata><Item name=\"STATISTICS_MINIMUM\">100</Item></GDALMetadata>",true),("<GDALMetadata><Item name=\"SCALE\" role=\"scale\">0.1</Item></GDALMetadata>",false)] {
        var f = Fixture(); let data = Data((xml+"\0").utf8); f.extra = [(42112,2,data.count,data)]
        try f.withFile { url in
            if accepted {
                let source = try GeoTIFFSource(url:url,confirmedDEMNAS:false)
                #expect(source.metadata.epsg == 4326)
            }
            else { #expect(throws:TerrainError.self) { try GeoTIFFSource(url:url,confirmedDEMNAS:false) } }
        }
    }
}

// Independent Apple ImageIO encoder exercises real LZW dictionary growth, not only hand-built literals.
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@Test func imageIOEncodedFloatingPointTIFF() throws {
    let width = 64, height = 64
    let values: [Float] = (0..<(width*height)).map { Float(($0*7919)%4093)/8 - 100 }
    let data = values.withUnsafeBytes { Data($0) }
    let provider = try #require(CGDataProvider(data:data as CFData))
    let image = try #require(CGImage(width:width,height:height,bitsPerComponent:32,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:[.floatComponents,.byteOrder32Little],provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    for compression in [1,5,8] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imageio-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at:url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,UTType.tiff.identifier as CFString,1,nil))
        let properties: [CFString:Any] = [kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFCompression:compression]]
        CGImageDestinationAddImage(destination,image,properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let reader = try TIFFReader(url:url)
        for row in 0..<height { for column in 0..<width {
            #expect(try reader.sample(column:column,row:row) == Double(values[row*width+column]))
        } }
    }
}

@Test(arguments:[false,true]) func otherElevationSampleTypes(bigEndian:Bool) throws {
    for (bits,format) in [(64,3),(16,2),(32,2),(16,1),(32,1)] {
        var fixture = Fixture(); fixture.bits = bits; fixture.sampleFormat = format; fixture.bigEndian = bigEndian
        if format != 1 { fixture.values[3] = -123 }
        try fixture.withFile { url in
            let source = try GeoTIFFSource(url:url,confirmedDEMNAS:false)
            #expect(try source.sample(column:3,row:0) == Double(fixture.values[3]))
            #expect(try source.sample(column:5,row:5) == 155)
        }
    }
}
