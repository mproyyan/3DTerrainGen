# Dynamic Grid + Adaptive Tiling

## User area and resolution

The project polygon has no application-level maximum in metres. The user chooses a positive spatial resolution in metres per terrain display cell. This choice is saved with the project; older projects default to 1 m. DEMNAS availability, raster sample budgets, the 256-axis terrain LOD, and device memory may still make a particular operation unavailable or coarser than requested. The app reports the actual terrain grid size. Model inputs retain the resolutions at which their frozen checkpoints were trained.

All window positions and CPT tests use the terrain origin's local WGS 84 east/north frame in physical metres. Coordinate conversion back to geographic space is refined against the ECEF local projection. Area dimensions are measured in metres; no algorithm assumes every cell is 1 m.

## Model C Flexible reconstruction

A single compatible area uses Model C Flexible directly. Larger areas are divided into 48 × 32 cell windows at 1 m spacing with 8 m physical overlap. Each window is clipped to the project polygon and receives only CPTs inside its physical bounds. Windows with no complete CPT remain **unknown** and run no model inference. Windows with inadequate depth or incompatible input are counted separately. Supported windows run sequentially, so sparse investigations do not allocate tensors for the full project.

Each tile's output is a local prediction. At an overlap, the renderer samples physical coordinates from all covering tiles, blends predictions with weights that taper near tile edges, and returns measured CPT voxels exactly. The seam regression test checks a smooth transition and observed-value precedence. No test establishes equivalence to a single global Model C inference, so the UI labels the output tiled/experimental and reports how many windows were unknown.

For memory control, the renderer keeps only reconstructed CPT-bearing windows, groups cells by window chunk, and increases its display step when exposed voxel count would exceed the approximate entity budget. The terrain surface is sampled onto a bounded raster LOD before RealityKit mesh creation. These budgets limit work per operation, not the polygon size that can be saved.

## DQN

The frozen DQN scorer and matching SchemaGAN reconstructor retain their original g24 (24 × 24 × 12 at 1 × 1 × 1 m) and g16 (16 × 16 × 16 at 2 × 2 × 1 m) contracts. On larger projects, overlapping 32 × 32 m candidate windows are clipped to the polygon. A deterministic rule selects **one** eligible window containing the most recently updated complete CPT, preferring more complete CPTs and then row/column. Only that window is scored. Q-values from distinct windows are never compared.

A successful large-area suggestion is labelled **DQN Windowed Experimental**, with a notice that the window choice and recommendation have not been validated against ground truth. It is not a whole-site optimum. A window lacking a supported CPT count, depth, valid terrain cells, or model output falls back to Heuristic with the reason. Model C Flexible is never substituted for the DQN reconstructor.

## Offline quality figures

The map presents reference physical-Ic RMSE for matching observed CPT counts (1, 2, 3, 5, 8). SchemaGAN V3 figures come from `cpt_super_learn/results/schemagan3d_v3_training_continuation/SCHEMAGAN_V3_TRAINING_CONTINUATION_REPORT.md`, paired evaluation of 400 synthetic validation volumes, hidden valid voxels. DQN V3 hybrid figures come from `cpt_super_learn/results/dqn_v3_final_hybrid/DQN_V3_FINAL_HYBRID_REPORT.md`, 1,000 synthetic test-ID volumes per CPT count, measured **after** adding the selected CPT. These are different evaluation splits and cannot be compared as a paired model ranking or interpreted as an error estimate for the current project. Windowed DQN has not been evaluated under that protocol. Model C Flexible visualization uses a different checkpoint and does not inherit the SchemaGAN figure.

DQN action candidates are also checked against the actual geographic coordinates of existing CPTs, so the app's two-metre placement rule is respected after grid snapping. The model does not receive road, vegetation, access, or permit information; suggested points require a site check.

## Synthetic verification on macOS

The following sizes were tested with an explicit fixture resolution. The app now chooses display resolution automatically from the polygon and 160-cell raster budget; model inference keeps its fixed training grid. Each fixture had one complete 16 m CPT near its centre, so empty tiles stayed unknown. Times below are per Model C reconstruction call after model compilation; peak RSS is the process high-water mark and includes model/runtime overhead, so it is not the incremental cost of a tile.

| Area (m) | Fixture resolution (m/sel) | Model C windows completed/planned | Model C inference (s) | Resident volume estimate | Process peak RSS | DQN |
|---|---:|---:|---:|---:|---:|---|
| 24 × 24 | 1 | 1/1 | 0.026 | 87,808 B | 66,437,120 B | single grid g24 |
| 32 × 32 | 2 | 1/1 | 0.050 | 172,032 B | 78,643,200 B | single grid g16 |
| 79 × 71 | 1 | 1/6 | 0.048 | 172,032 B | 78,643,200 B | windowed experimental |
| 200 × 150 | 2 | 2/30 | 0.094 | 344,064 B | 79,134,720 B | windowed experimental |
| 1,000 × 800 | 5 | 1/850 | 0.048 | 172,032 B | 79,183,872 B | windowed experimental |

The tests also check physical coordinate round trips, grid coverage, CPT-to-tile mapping, finite inference output, seam blending, restoration of observed Ic, and a windowed DQN result matching a direct single-window inference. The 24 m and 32 m direct DQN tests check selection against the independent Core ML Q-value argmax. No iPhone memory, frame-rate, or field ground-truth validation has been performed; large real investigations may need different display LOD and more CPT coverage.
