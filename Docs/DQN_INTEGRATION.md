# DQN recommendation integration

`DQNReconstructor.mlpackage` is a Core ML conversion of the frozen SchemaGAN V3 checkpoint used by the supplied `DQNScorer.mlpackage`. The source checkpoint is `cpt_super_learn/results/schemagan3d_v3_training_continuation/mse_continuation/best.pt`, SHA-256 `5694bb7b43efd7054a99fac8b74dadc5d74ebe6d291f42a8393b57fe9da52b64`. Conversion did not retrain or alter that checkpoint. The model's training normalization is mean `2.314278231778639`, standard deviation `0.27927494076233944`. This is distinct from the supplied Model C and its normalization.

The fixed Core ML inputs `sparse`, `mask`, and `idw`, and output `reconstruction`, are Float32 `[1,1,12,24,24]` in `[B,C,Z,Y,X]` order. Swift preprocessing uses 1 m grid spacing, depth centers 0.5–11.5 m, observed-value restoration, and physical inverse-distance-squared IDW. The DQN scorer accepts 28 Float32 features per candidate. The feature order follows `cpt_super_learn/dqn3d/v3/features.py`; a Swift test compares a fixture row against the Python implementation. For a fixed fixture, Core ML reconstruction differed from PyTorch by at most `2.950429916381836e-06` normalized Ic units on macOS.

The app runs the matching g24 or g16 reconstructor separately from the flexible Model C display model, then uses the 17 candidate and 11 global features to score legal cells. Replacing Model C does not change DQN’s grid contract. A recommendation is labelled DQN only after successful inference. Pending or incompatible input retains the existing geometric heuristic with an explicit fallback label and reason.

Current deployment supports g24 up to 24 × 24 m at 1 m XY resolution and g16 up to 32 × 32 m at 2 m XY resolution; g16 is selected when either span exceeds 24 m. Each CPT must provide Ic at all 12 (g24) or 16 (g16) depth centers without extrapolation. The direct single-grid path ends at 32 m in either direction. Larger polygons may use one eligible experimental local window; shallow profiles, missing models, failed inference, or no eligible window fall back to Heuristic. The app does not tile or rescale larger sites because that would change the model's training contract. No physical iPhone inference or field accuracy validation has been performed.

## Audit area and feature contract (2026-10-26)

The original 24 m guard was supported by the original deployed Core ML g24 contract, not merely a UI constant. `DQNReconstructor.mlpackage` requires `[1,1,12,24,24]`; the DQN preprocessing places the polygon on a local 1 m XY grid, normalizes observed Ic with the frozen SchemaGAN V3 training statistics, and builds physical inverse-distance-squared IDW. The original `DQNFeatureAdapter.swift` assumed 24 XY cells, 12 depth cells, and 1 m spacing; it now validates and handles exactly g24 or g16. The app now reports the measured east/north span and both supported grid limits with their resolutions when the area exceeds 32 m.

The scorer consumes **17 candidate features plus 11 global features** in the order of `results/dqn_v3_implementation/dqn_v3_feature_schema.json`. Grid-local coordinate fractions are `x/(nx-1)` and `y/(ny-1)`; nearest-CPT distance uses metres divided by the grid diagonal; the local neighborhood has a physical 4 m radius; global features explicitly include physical extents and spacing. Ic summary features use the SchemaGAN/DQN training mean and standard deviation. A test compares all 28 values of one Swift fixture row against the Python `build_state` reference. The candidate ordering and argmax tie-break follow the Python path.

The training grid catalog includes g12 (12 × 12 × 12 at 2 × 2 × 1 m), g16 (16 × 16 × 16 at 2 × 2 × 1 m, 32 m XY extent), and g24 (24 × 24 × 12 at 1 × 1 × 1 m). Thus the former 24 m limit was a deployment/export restriction; training includes a 32 m extent *at a different grid shape and resolution*. The g16 path now exports the **same frozen SchemaGAN V3 checkpoint** for `[1,1,16,16,16]`, uses 2 m XY / 1 m depth preprocessing and the original 28 feature semantics. A Core ML versus PyTorch fixture differed by at most `2.0265579223632812e-06` normalized Ic units. A Swift g16 feature row matches Python `build_state`, and a >24 m integration fixture selects the same candidate as the independent Core ML Q-value argmax. Windowing a larger site changes the observed-CPT context, local features, and Q-value comparison across windows; whole-area recommendations are not validated by this training catalog. Local coordinates are already used and do not increase the physical extent of a fixed 24-cell grid.

`ModelC_Flexible.mlpackage` returns a compatible *physical quantity* (Ic), but it comes from a different checkpoint and uses different normalization. Feeding its reconstruction into the DQN features would preserve the 28 names/order only after denormalization and DQN renormalization, while changing the reconstruction distribution seen during DQN training. No quantitative scorer validation establishes interchangeability. The display path therefore continues to use Model C Flexible unchanged; the DQN path uses its paired frozen SchemaGAN reconstructor. On incompatible inputs the app keeps the geometric Heuristic fallback.


## Verified deployment matrix

| Grid | Training catalog | Core ML reconstructor | Swift feature contract | Genuine Q-value test | Deployment |
|---|---|---|---|---|---|
| g24: 24×24×12, 1×1×1 m | Yes | Matching frozen checkpoint | Python 28-feature row match | Pass | Enabled through 24×24 m |
| g16: 16×16×16, 2×2×1 m | Yes | Matching frozen checkpoint; max normalized Ic difference 2.03e-6 | Python 28-feature row match | Pass on >24 m fixture | Enabled through 32×32 m; requires Ic through 15.5 m |
| g12: 12×12×12, 2×2×1 m | Yes | Not exported | Not implemented | Not run | Disabled |
| Larger than 32 m in either axis | No whole-area grid in catalog | One local g24/g16 window only | Whole-area ranking unvalidated | One-window Q test passes | DQN Windowed Experimental if eligible; otherwise Heuristic |

The Model C Flexible display model was not modified or substituted into the DQN pipeline. The validation above proves software contract and inference on synthetic fixtures, not field accuracy or physical-device performance.


For projects larger than 32 m, the app can now run a **single selected local window** and labels its result DQN Windowed Experimental. The latest complete CPT must belong to an eligible 32 × 32 m window; the rule selects among eligible windows before inference, with no Q-value comparison across windows. This is not validated as a whole-site optimum. Incompatible or unobserved windows keep Heuristic/unknown status. See `Docs/DYNAMIC_GRID_TILING.md`.
