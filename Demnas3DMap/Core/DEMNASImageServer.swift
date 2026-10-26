import Foundation

struct DownloadedDEM: Sendable {
    let url: URL
    let directory: URL
    let metadata: DEMMetadata
}

/// Downloads a bounded elevation raster from BIG's public DEMNAS ArcGIS ImageServer.
/// The service exports a bounding box; `RasterClippingService` subsequently clips it
/// to the exact polygon drawn in the map.
enum DEMNASImageServer {
    struct ExportRequest: Sendable {
        let bounds: (west: Double, south: Double, east: Double, north: Double)
        let width: Int
        let height: Int
        let url: URL
    }

    private static let endpoint = URL(string: "https://geoservices.big.go.id/raster/rest/services/DEMNAS/DEM_Indonesia/ImageServer/exportImage")!
    private static let serviceExtent = (west: 94.75, south: -11.25, east: 141.0, north: 6.25)
    // BIG's native source tiles currently return an undocumented ±1.134e38
    // sentinel in some areas. Requesting the first overview level instead
    // (just coarser than the source tile's 0.000150015° maximum pixel size)
    // yields valid DEMNAS elevations there.
    private static let minimumPixelSize = 2e-4
    private static let edgePaddingPixels = 2
    private static let maximumAxis = 2_000
    private static let maximumRequestedSamples = 3_500_000

    static func request(for polygon: [GeoPoint]) throws -> ExportRequest {
        try Geometry.validate(polygon.map(\.point))

        let west = polygon.map(\.longitude).min()!, east = polygon.map(\.longitude).max()!
        let south = polygon.map(\.latitude).min()!, north = polygon.map(\.latitude).max()!
        let spanX = east - west, spanY = north - south
        guard spanX > 0, spanY > 0 else { throw TerrainError("The selected area has no usable extent.") }

        // Request the first valid ImageServer overview level when possible, while
        // keeping bandwidth and the existing source-sample memory budget bounded.
        let usableAxis = Double(maximumAxis - edgePaddingPixels * 2)
        var pixelSize = max(minimumPixelSize, spanX / usableAxis, spanY / usableAxis,
                            sqrt((spanX * spanY) / Double(maximumRequestedSamples)))
        var width = Int(ceil(spanX / pixelSize)) + edgePaddingPixels * 2
        var height = Int(ceil(spanY / pixelSize)) + edgePaddingPixels * 2
        if width * height > maximumRequestedSamples {
            pixelSize *= sqrt(Double(width * height) / Double(maximumRequestedSamples))
            width = Int(ceil(spanX / pixelSize)) + edgePaddingPixels * 2
            height = Int(ceil(spanY / pixelSize)) + edgePaddingPixels * 2
        }
        guard (2...maximumAxis).contains(width), (2...maximumAxis).contains(height) else {
            throw TerrainError("The selected area is too large to download safely. Draw a smaller area.")
        }

        let bounds = (west: west - Double(edgePaddingPixels) * pixelSize,
                      south: south - Double(edgePaddingPixels) * pixelSize,
                      east: east + Double(edgePaddingPixels) * pixelSize,
                      north: north + Double(edgePaddingPixels) * pixelSize)
        guard bounds.west >= serviceExtent.west, bounds.south >= serviceExtent.south,
              bounds.east <= serviceExtent.east, bounds.north <= serviceExtent.north else {
            throw TerrainError("The selected area must remain inside DEMNAS coverage, including a small raster margin.")
        }

        let box = [bounds.west, bounds.south, bounds.east, bounds.north].map(decimal).joined(separator: ",")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "bbox", value: box),
            URLQueryItem(name: "bboxSR", value: "4326"),
            URLQueryItem(name: "imageSR", value: "4326"),
            URLQueryItem(name: "size", value: "\(width),\(height)"),
            URLQueryItem(name: "format", value: "tiff"),
            URLQueryItem(name: "pixelType", value: "F32"),
            URLQueryItem(name: "interpolation", value: "RSP_BilinearInterpolation"),
            // Keep the requested extent exact; non-square raster cells are supported
            // by the affine transform and are preferable to a silently expanded extent.
            URLQueryItem(name: "adjustAspectRatio", value: "false"),
            URLQueryItem(name: "noData", value: "nan"),
            URLQueryItem(name: "noDataInterpretation", value: "esriNoDataMatchAny"),
            URLQueryItem(name: "f", value: "image")
        ]
        guard let url = components.url else { throw TerrainError("Unable to construct the DEMNAS request.") }
        return .init(bounds: bounds, width: width, height: height, url: url)
    }

    static func download(for polygon: [GeoPoint]) async throws -> DownloadedDEM {
        let export = try request(for: polygon)
        try Task.checkCancellation()
        var request = URLRequest(url: export.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("Demnas3DMap", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TerrainError("DEMNAS did not return an HTTP response.") }
        guard (200...299).contains(http.statusCode) else {
            throw TerrainError("DEMNAS returned HTTP \(http.statusCode). Try again later.")
        }
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           type.contains("html") || type.contains("json") || type.hasPrefix("text/") {
            throw TerrainError("DEMNAS returned an error document instead of a GeoTIFF.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DEMNAS-\(UUID().uuidString)", isDirectory: true)
        let localURL = directory.appendingPathComponent("demnas.tif")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporaryURL, to: localURL)
            let reader = try TIFFReader(url: localURL)
            guard reader.width == export.width, reader.height == export.height else {
                throw TerrainError("DEMNAS returned an unexpected raster size. Try again later.")
            }
            let transform = AffineTransform(x0: export.bounds.west,
                                            a: (export.bounds.east - export.bounds.west) / Double(export.width), b: 0,
                                            y0: export.bounds.north, d: 0,
                                            e: -(export.bounds.north - export.bounds.south) / Double(export.height))
            try transform.validate()
            let noData = try noData(from: reader)
            let metadata = DEMMetadata(width: reader.width, height: reader.height, transform: transform,
                                       epsg: 4326, noData: noData,
                                       verticalReference: "EGM2008 orthometric height (EPSG:3855)",
                                       provenance: ["DEMNAS Indonesia via BIG ImageServer", "Raster exported directly for the selected area"],
                                       footprint: [
                                        .init(longitude: export.bounds.west, latitude: export.bounds.north),
                                        .init(longitude: export.bounds.east, latitude: export.bounds.north),
                                        .init(longitude: export.bounds.east, latitude: export.bounds.south),
                                        .init(longitude: export.bounds.west, latitude: export.bounds.south)
                                       ])
            return .init(url: localURL, directory: directory, metadata: metadata)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func noData(from reader: TIFFReader) throws -> Double? {
        guard let value = reader.string(42113) else { return nil }
        guard let noData = Double(value) else { throw TerrainError("DEMNAS returned an invalid NoData value.") }
        return noData
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
