# DEMNAS 3D Map

An iPhone-only SwiftUI app: select a polygon on Apple Maps, import a real elevation GeoTIFF, validate its geographic reference, and view the clipped terrain in RealityKit. Minimum deployment target: **iOS 17**. The project builds with Xcode 27 / Swift 6; no package downloads or native binary installation are required. The Swift package is a separate test harness for the same core source files used by the app.

## Run

Open `Demnas3DMap.xcodeproj`, choose an iPhone destination, and run. Use your signing team for a physical device.

1. Navigate the map with Draw off. Enable **Draw** and tap distinct vertices; dragging and pinching continue to navigate. Disable Draw whenever you want taps to leave the boundary unchanged.
2. Use Undo/Reset as needed, then Finish. Self-intersections, repeated vertices, and degenerate boundaries are rejected.
3. Import one `.tif`/`.tiff`. Select matching `.tfw`/`.tifw`/`.wld`, `.prj`, or `.tif.aux.xml` companions **in the same file-picker selection** when needed. iOS access to a TIFF does not grant access to neighboring files.
4. Confirm official DEMNAS provenance only if known. This supplies missing **vertical** information (metres, EGM2008), never a horizontal CRS.
5. Use Frame DEM and the orange footprint to compare the imported tile with the cyan selection.
6. Generate 3D. Drag to orbit, pinch to zoom, two-finger drag to pan; Reset camera restores the initial view. Details preserve the CRS, vertical reference, original height origin, and processing provenance.

All elevation processing is local. Apple Maps imagery still depends on network/cache availability. No location permission is requested because the app does not track the device.

## Architecture

- `Core/Geometry.swift`: coordinate capture model, polygon validation, ear triangulation, convex clipping.
- `Core/TIFFReader.swift`: bounded, read-only, seek-based TIFF parsing and block decoding; no ImageIO color conversion of elevation samples.
- `Core/DEMMetadata.swift`: GeoKeys, pixel-center/corner semantics, metadata recovery and conflict validation.
- `Core/CoordinateTransformer.swift`: supported CRS conversions, invertible six-term affine transform, WGS 84 local east/north metric frame.
- `Core/TerrainPipeline.swift`: security-scoped import, replaceable `DEMRasterSource`, raster window/mask, boundary-clipped triangle mesh, original elevation metadata.
- `TerrainSession.swift`: main-actor UI state, cancellable worker tasks, import lifetime.
- `Views/TerrainMapView.swift`: native Map/MapReader/MapPolygon and fileImporter.
- `Views/Terrain3DView.swift`: asynchronous MeshDescriptor resource loading and a non-AR RealityKit camera with touch controls.

To support a future tile catalog, implement `DEMRasterSource` with catalog-provided metadata and sample access. The clipping/mesh pipeline does not depend on TIFF. A tile catalog must carry authoritative CRS/footprint provenance; filename and pixel dimensions are never substitutes.

## Geographic interpretation

GeoTIFF ModelPixelScale+ModelTiepoint or ModelTransformation define the affine mapping. PixelIsPoint is shifted by half a pixel into a consistent corner-based transform. World files are also converted from sample-center origins. Rotated/sheared transforms are supported. Footprints are derived from raster bounds and densified before geographic conversion.

Case A uses embedded CRS and georeferencing. Case B may assign a missing CRS from a companion's explicit root EPSG identifier. Case C can recover the transform from a world file or PAM auxiliary GeoTransform, but still needs a CRS. Conflicts are errors. There is no filename-based CRS or tile-position inference. Unnamed/custom WKT and missing authoritative references produce actionable errors.

Apple Maps coordinates enter as WGS 84 longitude/latitude. Transforming them into the DEM CRS is distinct from assigning a missing CRS identifier. Supported CRSs: EPSG:4326, EPSG:3857, and WGS 84 UTM EPSG:32601–32660/32701–32760. UTM is restricted to its normal latitude range and within six degrees of its central meridian. No approximate datum substitutions are made. Map edges are adaptively subdivided in Mercator space until their projected midpoint deviation is at most 0.02 raster pixels. The mesh boundary matches that transformed polygon to numerical clipping tolerance; it is not claimed to have zero projection approximation error.

The complete boundary must fit within the raster's sample-center hull: the outer half-pixel footprint cannot support interpolation without extrapolation. Every original source sample in the window is checked before downsampling; NoData cells intersecting the polygon reject generation. Interpolation requiring invalid neighbors also rejects generation. NoData is never filled, averaged into valid terrain, or bridged silently.

The render grid has up to 160 samples on each axis. Each grid triangle is intersected with the triangulated polygon, including concave edges. New boundary heights are barycentrically interpolated on that triangle. Original source extrema within the selection are retained alongside boundary extrema. A separate mask identifies sample centers inside the polygon; outside samples are retained only as interpolation support. Normals are accumulated across shared vertices, with upward-facing winding.

Horizontal positions use double-precision WGS 84 ECEF projected onto local east/north axes; X=east, Z=−north, Y=height minus a retained common elevation origin. An equal display scale on all three axes preserves 1:1 horizontal/vertical proportions. This is a local planar height field, limited to 25 km from the first vertex. Area is approximate in the local metric plane. EGM2008 orthometric heights are not mislabeled as ellipsoid heights; no vertical datum transformation is attempted.

## Native reader scope and GDAL evaluation

Supported: classic TIFF, either byte order; single-band grayscale Float32/Float64 or signed/unsigned 16/32-bit integers; strips or tiles; uncompressed, TIFF LZW, and zlib Deflate; integer horizontal predictor and floating-point predictor; GeoTIFF keys, affine georeferencing and GDAL NoData. Harmless GDAL statistics are accepted; nonidentity scale/offset or non-metre height units are rejected. Companion recovery accepts explicit EPSG text or root-authority WKT and PAM XML. Only explicitly selected matching companions are used.

Unsupported inputs are rejected: BigTIFF, JPEG/PackBits/LERC/ZSTD, multiband/color rasters, alternate TIFF orientations, internal validity masks/SubIFDs, multiple primary images, custom/other datums, arbitrary GCP fitting, scaled bands, and ambiguous CRS metadata. External `.msk`, `.ovr`, RPC, and other sidecars are not supported; do not use a raster whose validity depends on them. This is not a general replacement for GDAL. Without a real file from the user's DEMNAS download, compatibility with that specific tile is **unverified**.

GDAL is a sensible broader-format backend, but is not bundled here. A reliable iOS integration would require pinned native GDAL, PROJ (including `proj.db` and any datum grids), TIFF/GeoTIFF and codec dependencies built as an XCFramework for device arm64 and simulator arm64/x86_64, license notices, and a C/Objective-C wrapper around GDALOpenEx/GDALRasterIO/OSR coordinate transforms. Its build/data packaging needs device validation. Invoking `gdalwarp` or other shell programs on iOS is not an integration strategy. The source protocol allows that backend to replace this decoder without rewriting clipping or rendering.

Limits: 2 GB imported TIFF; 1 MB each companion; 16 MB decoded strip/tile; 24 MB decoded block cache; four million source samples per extraction; up to 128 boundary vertices after projection subdivision; 200,000 mesh vertices/triangles. Mesh sampling reduces fine detail and can smooth narrow peaks. Import copies the file to private temporary storage; only overlapping blocks are decoded during extraction. Cancellation is checked during reading/clipping/meshing, but a single file-copy/decompression operation must finish first. No persistent import catalog, tile mosaicking, geoid grids, wireframe, or project save/export is implemented.

## Validation

Verified in this workspace on 12 October 2026: **13 core tests passed**, unsigned iPhone and iPhone Simulator builds succeeded, and the app launched in the iOS 27 iPhone 18 Pro simulator with the map/control layout visually inspected. Decoder tests also read floating-point TIFFs encoded independently by Apple ImageIO, including LZW dictionary growth. Real-tile accuracy, touch interaction, and physical-device file-provider access remain unverified.

Run the shared-core tests on macOS:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Unsigned iPhone build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Demnas3DMap.xcodeproj -scheme Demnas3DMap \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Tests generate synthetic TIFF fixtures **only in the test target**. They cover byte order, compression/predictors, geographic bounds, PixelIsPoint, rotated transforms, CRS controls/round trips, missing/conflicting metadata, auxiliary recovery, source-file copying, self-intersections, coverage rejection, NoData before downsampling, concave polygon mesh area, upward normals, and interpolated mesh heights. Coordinate-capture tests cover the selection model; actual MapReader screen-to-map conversion still needs an interactive map test.

Manual acceptance with a genuine DEMNAS tile remains necessary: draw a boundary whose location is independently known, compare the orange footprint with authoritative tile bounds, generate terrain, inspect slopes and extrema against known source values, exercise all viewer gestures, cancel a large job, and test Files/iCloud security-scoped imports on a physical iPhone. No real DEMNAS tile was supplied with the request.

## References

- [BIG DEMNAS product description](https://www.big.go.id/en/content/produk/demnas): resolution and EGM2008 vertical reference.
- [Official DEMNAS download portal](https://tanahair.indonesia.go.id/portal-web/unduh/demnas).
- [OGC GeoTIFF specification](https://docs.ogc.org/is/19-008r4/19-008r4.html): keys and raster georeferencing.
- [GDAL GeoTIFF driver](https://gdal.org/en/stable/drivers/raster/gtiff.html): format scope, NoData and metadata conventions.
- [GDAL native build requirements](https://gdal.org/en/stable/development/building_from_source.html).
- [Apple MapReader](https://developer.apple.com/documentation/mapkit/mapreader) and [MeshDescriptor](https://developer.apple.com/documentation/realitykit/meshdescriptor).
