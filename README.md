# DEMNAS 3D Map

An iPhone-only SwiftUI app: select a polygon on Apple Maps, download the matching DEMNAS raster from BIG's ImageServer, and view the polygon-clipped terrain in RealityKit. Minimum deployment target: **iOS 17**. The project builds with Xcode 27 / Swift 6; no package downloads or native binary installation are required. The Swift package is a separate test harness for the same core source files used by the app.

## Run

Open `Demnas3DMap.xcodeproj`, choose an iPhone destination, and run. Use your signing team for a physical device.

1. Navigate the map with Draw off. Enable **Draw** and tap distinct vertices; dragging and pinching continue to navigate. Disable Draw whenever you want taps to leave the boundary unchanged.
2. Use Undo/Reset as needed, then Finish. Self-intersections, repeated vertices, and degenerate boundaries are rejected.
3. Choose **Ambil DEMNAS & Buat 3D**. The app requests a padded bounding box from BIG's public `ImageServer`, clips the result to the exact drawn polygon, and builds the mesh. The server download is cancellable.
4. Use Frame DEM and the orange footprint to compare the downloaded raster extent with the cyan selection.
5. Drag to orbit, pinch to zoom, two-finger drag to pan; Reset camera restores the initial view. Details preserve the CRS, vertical reference, original height origin, and processing provenance.

The request sends only the selected bounding box to BIG; raster clipping and mesh processing run locally. Apple Maps imagery and DEMNAS download require network access. No location permission is requested because the app does not track the device.

## Architecture

- `Core/Geometry.swift`: coordinate capture model, polygon validation, ear triangulation, convex clipping.
- `Core/TIFFReader.swift`: bounded, read-only, seek-based TIFF parsing and block decoding; no ImageIO color conversion of elevation samples.
- `Core/DEMNASImageServer.swift`: bounded `exportImage` request, response validation, and authoritative request-derived EPSG:4326/EGM2008 metadata.
- `Core/DEMMetadata.swift`: GeoKeys, pixel-center/corner semantics, and generic GeoTIFF metadata validation used by the decoder tests.
- `Core/CoordinateTransformer.swift`: supported CRS conversions, invertible six-term affine transform, WGS 84 local east/north metric frame.
- `Core/TerrainPipeline.swift`: replaceable `DEMRasterSource`, raster window/mask, boundary-clipped triangle mesh, original elevation metadata.
- `TerrainSession.swift`: main-actor UI state and cancellable fetch/mesh worker task.
- `Views/TerrainMapView.swift`: native Map/MapReader/MapPolygon and DEMNAS terrain action.
- `Views/Terrain3DView.swift`: asynchronous MeshDescriptor resource loading and a non-AR RealityKit camera with touch controls.

To support a future tile catalog, implement `DEMRasterSource` with catalog-provided metadata and sample access. The clipping/mesh pipeline does not depend on TIFF. A tile catalog must carry authoritative CRS/footprint provenance; filename and pixel dimensions are never substitutes.

## Geographic interpretation

BIG's request declares EPSG:4326 and the exact output extent. The app derives its corner-based affine transform from that request rather than trusting optional GeoTIFF CRS tags in the response. This avoids inference from filename or pixel dimensions. DEMNAS elevations are recorded as EGM2008 orthometric metres from the service metadata.

Apple Maps coordinates enter as WGS 84 longitude/latitude. Transforming them into the DEM CRS is distinct from assigning a missing CRS identifier. Supported CRSs: EPSG:4326, EPSG:3857, and WGS 84 UTM EPSG:32601–32660/32701–32760. UTM is restricted to its normal latitude range and within six degrees of its central meridian. No approximate datum substitutions are made. Map edges are adaptively subdivided in Mercator space until their projected midpoint deviation is at most 0.02 raster pixels. The mesh boundary matches that transformed polygon to numerical clipping tolerance; it is not claimed to have zero projection approximation error.

The complete boundary must fit within the raster's sample-center hull: the outer half-pixel footprint cannot support interpolation without extrapolation. Every original source sample in the window is checked before downsampling; NoData cells intersecting the polygon reject generation. Interpolation requiring invalid neighbors also rejects generation. NoData is never filled, averaged into valid terrain, or bridged silently.

The render grid has up to 160 samples on each axis. Each grid triangle is intersected with the triangulated polygon, including concave edges. New boundary heights are barycentrically interpolated on that triangle. Original source extrema within the selection are retained alongside boundary extrema. A separate mask identifies sample centers inside the polygon; outside samples are retained only as interpolation support. Normals are accumulated across shared vertices, with upward-facing winding.

Horizontal positions use double-precision WGS 84 ECEF projected onto local east/north axes; X=east, Z=−north, Y=height minus a retained common elevation origin. An equal display scale on all three axes preserves 1:1 horizontal/vertical proportions. This is a local planar height field, limited to 25 km from the first vertex. Area is approximate in the local metric plane. EGM2008 orthometric heights are not mislabeled as ellipsoid heights; no vertical datum transformation is attempted.

## Native reader scope and GDAL evaluation

Supported: classic TIFF, either byte order; single-band grayscale Float32/Float64 or signed/unsigned 16/32-bit integers; strips or tiles; uncompressed, TIFF LZW, and zlib Deflate; integer horizontal predictor and floating-point predictor; GeoTIFF keys, affine georeferencing and GDAL NoData. The DEMNAS ImageServer response is required to be a single-band Float32 TIFF whose dimensions exactly match the requested export size.

Unsupported inputs are rejected: BigTIFF, JPEG/PackBits/LERC/ZSTD, multiband/color rasters, alternate TIFF orientations, internal validity masks/SubIFDs, multiple primary images, custom/other datums, arbitrary GCP fitting, scaled bands, and ambiguous CRS metadata. External `.msk`, `.ovr`, RPC, and other sidecars are not supported; do not use a raster whose validity depends on them. This is not a general replacement for GDAL. Without a real file from the user's DEMNAS download, compatibility with that specific tile is **unverified**.

GDAL is a sensible broader-format backend, but is not bundled here. A reliable iOS integration would require pinned native GDAL, PROJ (including `proj.db` and any datum grids), TIFF/GeoTIFF and codec dependencies built as an XCFramework for device arm64 and simulator arm64/x86_64, license notices, and a C/Objective-C wrapper around GDALOpenEx/GDALRasterIO/OSR coordinate transforms. Its build/data packaging needs device validation. Invoking `gdalwarp` or other shell programs on iOS is not an integration strategy. The source protocol allows that backend to replace this decoder without rewriting clipping or rendering.

Limits: ImageServer requests are capped at 2,000 pixels on either axis and about 3.5 million source samples; 16 MB decoded strip/tile; 24 MB decoded block cache; four million source samples per extraction; up to 128 boundary vertices after projection subdivision; 200,000 mesh vertices/triangles. Mesh sampling reduces fine detail and can smooth narrow peaks. The downloaded TIFF lives only in private temporary storage while the mesh is built. Cancellation is checked during download, reading, clipping, and meshing. No persistent raster cache, tile mosaicking, geoid grids, wireframe, or project save/export is implemented.

## Validation

Verified in this workspace on 20 October 2026: **23 core tests passed** and an unsigned iPhone Simulator build succeeded. The BIG endpoint was sampled with a small request and returned an uncompressed 32-bit TIFF. The client requests the first overview level because the current native service tiles can contain undocumented ±1.134e38 sentinels; out-of-range samples are rejected rather than rendered. Decoder tests also read floating-point TIFFs encoded independently by Apple ImageIO, including LZW dictionary growth. Real-terrain accuracy, touch interaction, and physical-device networking remain unverified.

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

Manual acceptance against DEMNAS remains necessary: draw a boundary whose location is independently known, compare the orange footprint with the selected area, generate terrain, inspect slopes and extrema against known source values, exercise all viewer gestures, cancel a large job, and test network errors on a physical iPhone.

## References

- [BIG DEMNAS product description](https://www.big.go.id/en/content/produk/demnas): resolution and EGM2008 vertical reference.
- [BIG DEMNAS ImageServer](https://geoservices.big.go.id/raster/rest/services/DEMNAS/DEM_Indonesia/ImageServer): source service and `exportImage` operation.
- [OGC GeoTIFF specification](https://docs.ogc.org/is/19-008r4/19-008r4.html): keys and raster georeferencing.
- [GDAL GeoTIFF driver](https://gdal.org/en/stable/drivers/raster/gtiff.html): format scope, NoData and metadata conventions.
- [GDAL native build requirements](https://gdal.org/en/stable/development/building_from_source.html).
- [Apple MapReader](https://developer.apple.com/documentation/mapkit/mapreader) and [MeshDescriptor](https://developer.apple.com/documentation/realitykit/meshdescriptor).

## Sequential CPT proof of concept

The terrain viewer now includes an on-device CPT investigation workflow. **DRL and SchemaGAN are not implemented.** Soil interpretations, spatial coverage, strengths, recommendations, and completion are explicitly presented as simulations; they are not validated geotechnical design results.

1. Draw the boundary, choose **Ambil DEMNAS & Buat 3D**, and wait for the terrain to be generated.
2. Return to the map and choose **Tambah CPT**, then tap inside the terrain. Points must be at least 2 m apart (maximum 32). A point is saved immediately as waiting for field testing/data.
3. Open the point and paste a CSV profile, import a UTF-8 CSV from Files, or choose **Isi contoh sintetis** for a labeled demonstration dataset.
4. Review assumptions and choose **Simpan & generate lapisan**. Layer intervals, mean Ic, and applicable illustrative strengths appear beneath the editor.
5. Open **3D** to inspect the surface, subsurface columns, or a half cutaway. Depth can be exaggerated 1×/5×/10× independently of terrain elevation; the selected scale remains visible.
6. Open **Investigasi** to adopt the next simulated candidate, perform the field test, and submit its profile. The candidate is selected by maximum distance to existing CPTs among a bounded set of terrain triangle centroids, not by DRL or information gain. Field access is not evaluated.

Choose the scenario in **Investigasi**, before submitting the first profile:

- **Homogen · 1 CPT:** completion after one submitted profile; spatial extrapolation assumes lateral homogeneity.
- **Bervariasi · 3 CPT:** completion after three submitted profiles. Before completion, the display uses a geometric support radius `sqrt(area) × (0.22 + 0.10 × (completed − 1))`. This is a demo coverage mask, not a probability or calibrated uncertainty measure.

Pending points prevent completion and suppress additional automatic candidates. Editing results updates the interpretation and scene; deleting a point recomputes the state and can reopen the investigation. Additional manual points remain possible after scenario completion. If no candidate meets the spacing requirement, the UI explains that the scenario is incomplete.

### Input and interpretation contract

CSV header, in this exact order (header matching is case-insensitive):

```csv
depth_m,qc_mpa,fs_kpa,u2_kpa
0.5,0.650,42.0,
1.0,0.650,42.0,100
2.0,0.700,45.0,120
```

Use comma delimiters, decimal points, and no quoted fields. The parser accepts CRLF/LF and UTF-8 BOM. It requires 2–5,000 rows, at most 1 MB, strictly increasing depths in `(0, 200]` m, and positive finite qc/fs. Missing u2 is allowed, including a mixed profile; finite negative u2 is retained. There is no automatic sorting, duplicate removal, or conversion of unspecified units.

- qc in MPa is converted to kPa before `qt = qc + u2(1−a)`. A blank u2 uses `qt ≈ qc` and records that limitation.
- Total stress uses a constant user-entered unit weight (default 18 kN/m³); equilibrium pressure is hydrostatic below the entered water table (default 2 m). The cone area ratio defaults to 0.8 and Nkt to 15. Invalid ranges and nonpositive normalization denominators are rejected.
- Ic uses **Qt**, base-10 logarithms, and Fr in percent. Three illustrative behavior groups use Ic < 2.05 (sand-like), 2.05–2.6 (transitional), and ≥ 2.6 (clay-like). This does not reproduce every zone of the Robertson charts or use Qtn iteration.
- Layer segmentation applies a median over up to three adjacent samples and merges runs thinner than 0.5 m. Boundaries between samples are midpoints. Layers span only the first through last measured depth; gaps > 1 m trigger a note. Thin layers may be lost, and boundaries require engineer review.
- Clay-like samples use `su = (qt − σv0)/Nkt`. Sand-like samples use a deliberately illustrative **30/34/38° lookup**, not a claimed Kulhawy–Mayne correlation. Transitional samples have no strength estimate. Layer averages use only sample estimates that support the corresponding behavior; no statistical confidence interval is claimed.

### Spatial model and persistence

CPT surface elevations are sampled from the rendered DEM and retain its vertical datum. This PoC assumes vertical penetration and uses DEM ground elevation, not a surveyed CPT collar elevation. All subsurface objects share the terrain's local east/north frame and common display transform.

The spatial visualization consists of a bounded 14 × 14 grid of columns. Each supported column extends the **nearest completed CPT profile relative to local ground depth**. It does not match geological horizons across CPTs or perform SchemaGAN interpolation. Cells crossing the polygon boundary or concave notches are omitted, leaving visible edge gaps. Gray translucent columns indicate unsupported spatial coverage or unmeasured depth; the depth below the deepest profile remains outside the displayed model. Narrow columns at actual CPT locations show their interpreted profiles. A half cutaway exposes the interior without changing any computed data.

One project is saved atomically in the app's Application Support directory, including the polygon, terrain snapshot, CPT inputs, assumptions, data origin, derived profiles, scenario, and timestamps. Unapplied editor drafts are saved when the editor closes. The project restores on relaunch without retaining the temporary source TIFF; fetching terrain for a new area requires starting a new area. **Area baru** asks before clearing the saved project. This is one local project, without cloud sync or project export.

### Relationship to the research paper

Based conceptually on Zuada Coelho, Smyrniou & Campos Montero, *Optimizing geotechnical in-situ site investigations using Deep Reinforcement Learning*, Geodata and AI 6 (2026), 100038, [DOI](https://doi.org/10.1016/j.geoai.2025.100038). The paper uses DQN to choose horizontal steps in synthetic 2D Ic sections and SchemaGAN for interpolation. Its episodes end at the profile boundary. Arbitrary polygon domains, this 3D visualization, strength estimates, and the count-based completion scenarios are PoC additions, not reproduced or validated results from that paper.

PoC validation on 13 October 2026: all **21 core tests passed** (13 existing terrain tests plus 8 CPT/spatial/persistence tests), and unsigned iPhone and Simulator builds succeeded. Interactive QA on an isolated iOS 27 Simulator with synthetic terrain verified placing the first point, generating layers and behavior-specific strengths from the example CSV, the next-point recommendation, restoring the saved project on relaunch, and the 3D cutaway/depth controls. The full three-profile sequence is covered by core state tests; its final end-to-end UI rerun was not completed because automatic approval review hit a usage limit. Real CPT datasets, physical-device interaction, and geological accuracy remain unverified.
