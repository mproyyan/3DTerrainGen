# Uncertainty V2 end-to-end audit — 2026-11-04

## Data flow

`saveCPT` saves interpreted Ic and updates `updatedAt`, then calls
`refreshInvestigation`. The refresh invalidates the old reconstruction when
complete CPT data, CPT coordinates, grid resolution, or polygon changes.
SchemaGAN V4.2 Flexible reconstructs Ic; DQN V4.5 receives that volume; a
separate background task computes Uncertainty V2 from the same volume. The
renderer redraws after the volume and again after the risk map arrive.

A newly placed CPT without a saved Ic profile provides no new observation.
The previous reconstruction and risk remain until the profile is saved.

## Findings and minimal fix

- Previously, `refreshDQNIfNeeded` cleared the risk map on every refresh but
  did not always increment `reconstructionVersion`. RealityKit could keep
  displaying stale transparency while the UI label disappeared. Risk now
  invalidates with the reconstruction input, which increments the renderer
  version. A pending CPT leaves the valid measured-data map in place.
- The old reconstruction cache key contained CPT ID and timestamp only. It now
  also includes CPT coordinates, grid resolution, and polygon coordinates.
  Changes to project grid resolution use `setSpatialResolutionMeters`, which
  validates the new value and refreshes both ML outputs.
- Measured voxels are masked out of Uncertainty V2 and rendered at opacity 1.
  Risk opacity uses the same fixed 0–1 Ic visual range for every CPT count.
- Risk updates previously incremented the reconstruction version, which could
  refocus the 3D camera when background risk inference finished. A separate
  risk version now rebuilds transparency without changing the camera target.

## Tests

The automated cases cover 24×24×12 at 1/1/1 m; 48×32×16 at 2/3/1.5 m;
96×96×32 at 4/5/2 m; 1, 4, and 8 CPTs; mask behavior; physical spacing;
changes in CPT site and count; input-key changes for coordinate, resolution,
and polygon; fixed opacity; tree traversal; and 48 Python JSON reference rows.
Some unmeasured voxels can retain the same risk after a CPT is added because
the regression trees map both feature rows to the same leaves. Other voxels
near the new CPT change, and measured voxels become excluded from risk.

## Profiling on Apple Silicon Mac

| Grid / spacing (m) / CPT | Debug features | Debug trees | Debug full map | Release features | Release trees | Release full map | Process peak RSS | Risk-map Float array |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 24×24×12 / 1,1,1 / 1 | 0.005 s | 0.296 s | 0.319 s | 0.001 s | 0.003 s | 0.004 s | 37.6–43.6 MiB | 0.026 MiB |
| 48×32×16 / 2,3,1.5 / 4 | 0.027 s | 1.072 s | 1.120 s | 0.002 s | 0.012 s | 0.015 s | 39.7–45.6 MiB | 0.094 MiB |
| 96×96×32 / 4,5,2 / 8 | 0.456 s | 13.002 s | 13.773 s | 0.023 s | 0.140 s | 0.160 s | 76.8–77.4 MiB | 1.125 MiB |

Peak RSS includes the test process, model, and temporary benchmark arrays; it
is not app memory on iPhone. The app computes the map in a background task.
Debug tests have much higher tree traversal time than optimized Release tests.

For all-valid rectangular volumes, the renderer's current LOD loops select
about 2,084, 1,288, and 1,960 exposed-plus-observed voxel entities for these
three grids. These are geometry counts, not measured RealityKit build times.
Actual frame time and peak memory of the renderer on iPhone remain unmeasured;
they require navigating to the 3D screen on a physical device and recording an
Instruments trace. The estimated risk is experimental and has not been checked
against ground truth for the current field site.
