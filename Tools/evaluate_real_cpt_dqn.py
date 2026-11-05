"""Retrospective six-site field CPT pilot for the frozen SchemaGAN/DQN pair.

This is a constrained known-site experiment, not validation of the app's wide-area
window selector or an estimate of full-volume ground-truth error.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd


EXPECTED_SCHEMAGAN = "5694bb7b43efd7054a99fac8b74dadc5d74ebe6d291f42a8393b57fe9da52b64"
EXPECTED_DQN = "687539d5ad2606b198f2aadfaa6761bc9d9968ec8ce1fd2c915350413530345a"
SCENARIO = "dry_gamma18"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_inputs(root: Path):
    from synthetic3d.v2.core import Grid

    metadata = json.loads((root / "results/real_world_testing/real_cpt_metadata.json").read_text())
    grid = Grid(**metadata["grid"])
    if (grid.nx, grid.ny, grid.nz, grid.dx_m, grid.dy_m, grid.dz_m) != (24, 24, 12, 1.0, 1.0, 1.0):
        raise ValueError("real CPT grid does not match the frozen g24 contract")
    frame = pd.read_csv(root / "results/real_world_testing/real_cpt_ic_profiles.csv")
    frame = frame.loc[frame.scenario == SCENARIO].copy()
    sites = {}
    for site_id, group in frame.groupby("cpt_id"):
        group = group.sort_values("grid_z")
        if group.grid_z.tolist() != list(range(grid.nz)):
            raise ValueError(f"incomplete depth profile: {site_id}")
        xy = {(int(row.grid_x), int(row.grid_y)) for row in group.itertuples()}
        if len(xy) != 1:
            raise ValueError(f"inconsistent XY for {site_id}")
        values = group.Ic.to_numpy(dtype=np.float32)
        if not np.isfinite(values).all():
            raise ValueError(f"nonfinite Ic for {site_id}")
        sites[site_id] = (xy.pop(), values)
    if len(sites) != 6 or len({xy for xy, _ in sites.values()}) != 6:
        raise ValueError("expected six unique field CPTs")
    return grid, sites, metadata


def coverage_distance(grid, observed_xy: set[tuple[int, int]]) -> float:
    all_xy = np.array([grid.xy_m(x, y) for x in range(grid.nx) for y in range(grid.ny)])
    known_xy = np.array([grid.xy_m(*site) for site in sorted(observed_xy)])
    return float(np.linalg.norm(all_xy[:, None] - known_xy[None], axis=2).min(axis=1).mean())


def choose_site(policy, prediction, observed_xy, grid, access_mask, agent):
    from dqn3d.v3.features import build_state

    observed_mask = np.zeros((grid.nx, grid.ny, grid.nz), dtype=bool)
    for x, y in observed_xy:
        observed_mask[x, y, :] = True
    state = build_state(prediction, observed_mask, np.ones_like(observed_mask), grid, access_mask)
    candidate_xy = state.candidate_xy
    known = np.array([grid.xy_m(*xy) for xy in sorted(observed_xy)])
    candidates = np.array([grid.xy_m(int(x), int(y)) for x, y in candidate_xy])
    nearest = np.linalg.norm(candidates[:, None] - known[None], axis=2).min(axis=1)
    legal = np.flatnonzero(nearest >= 2.0 - 1e-9)  # app's physical CPT placement minimum
    if not len(legal):
        raise ValueError("no legal measured-site candidate")
    if policy == "dqn":
        scores = agent.scores(state)[legal]
        selected_index = int(legal[int(np.argmax(scores))])
    elif policy == "uniform":
        selected_index = int(legal[int(np.argmax(nearest[legal]))])
    else:
        raise ValueError(policy)
    return tuple(map(int, candidate_xy[selected_index])), float(nearest[selected_index]), int(len(legal))


def predict(reconstructor, grid, sites, observed_xy):
    shape = (grid.nx, grid.ny, grid.nz)
    values = np.zeros(shape, dtype=np.float32)
    mask = np.zeros(shape, dtype=bool)
    by_xy = {xy: profile for xy, profile in sites.values()}
    for x, y in observed_xy:
        values[x, y, :] = by_xy[x, y]
        mask[x, y, :] = True
    prediction, _ = reconstructor.predict(values, mask, np.ones(shape, dtype=bool), grid)
    return prediction


def evaluate(root: Path) -> dict:
    sys.path.insert(0, str(root))
    from dqn3d.v3.adapter import FrozenV3Reconstructor
    from dqn3d.v3.agent import CandidateDQNAgent

    grid, sites, metadata = load_inputs(root)
    schema_checkpoint = root / "results/schemagan3d_v3_training_continuation/mse_continuation/best.pt"
    dqn_checkpoint = root / "results/dqn_v3_scaled_pilot_2000e/run/best.pt"
    if sha256(schema_checkpoint) != EXPECTED_SCHEMAGAN or sha256(dqn_checkpoint) != EXPECTED_DQN:
        raise ValueError("frozen model identity mismatch")
    reconstructor = FrozenV3Reconstructor(
        schema_checkpoint,
        root / "results/schemagan3d_v3_training_continuation/mse_continuation_config.json",
        root / "data/synthetic3d_v2/schemagan_v3_24k",
    )
    agent, agent_metadata = CandidateDQNAgent.load(dqn_checkpoint)
    if agent_metadata.get("schemagan_sha256") != EXPECTED_SCHEMAGAN:
        raise ValueError("DQN checkpoint is not paired with the SchemaGAN checkpoint")
    agent.online.eval()
    access_mask = np.zeros((grid.nx, grid.ny), dtype=bool)
    for xy, _ in sites.values():
        access_mask[xy] = True
    by_xy = {xy: profile for xy, profile in sites.values()}
    rows = []
    for start_id in sorted(sites):
        start_xy = sites[start_id][0]
        observed = {policy: {start_xy} for policy in ("dqn", "uniform")}
        for step in (1, 2):
            selected = {}
            for policy in observed:
                before = predict(reconstructor, grid, sites, observed[policy])
                xy, distance, legal_count = choose_site(
                    policy, before, observed[policy], grid, access_mask, agent
                )
                if xy in observed[policy]:
                    raise ValueError("duplicate selected CPT")
                observed[policy].add(xy)
                selected[policy] = (xy, distance, legal_count)
            common_hidden = sorted(set(by_xy) - observed["dqn"] - observed["uniform"])
            if not common_hidden:
                raise ValueError("no common hidden CPT profiles")
            for policy in observed:
                after = predict(reconstructor, grid, sites, observed[policy])
                errors = np.concatenate([after[xy] - by_xy[xy] for xy in common_hidden])
                xy, distance, legal_count = selected[policy]
                rows.append({
                    "initial_cpt": start_id,
                    "observed_cpt_count": step + 1,
                    "policy": policy,
                    "selected_xy": list(xy),
                    "selected_distance_m": distance,
                    "legal_known_site_candidates": legal_count,
                    "common_hidden_cpt_count": len(common_hidden),
                    "common_hidden_ic_rmse": float(np.sqrt(np.mean(errors**2))),
                    "mean_grid_distance_to_cpt_m": coverage_distance(grid, observed[policy]),
                })
    summary = {}
    for count in (2, 3):
        pairs = []
        for start_id in sorted(sites):
            a = next(row for row in rows if row["initial_cpt"] == start_id and row["observed_cpt_count"] == count and row["policy"] == "dqn")
            b = next(row for row in rows if row["initial_cpt"] == start_id and row["observed_cpt_count"] == count and row["policy"] == "uniform")
            pairs.append((a, b))
        delta = [a["common_hidden_ic_rmse"] - b["common_hidden_ic_rmse"] for a, b in pairs]
        summary[str(count)] = {
            "starts": len(pairs),
            "mean_dqn_rmse": float(np.mean([a["common_hidden_ic_rmse"] for a, _ in pairs])),
            "mean_uniform_rmse": float(np.mean([b["common_hidden_ic_rmse"] for _, b in pairs])),
            "mean_paired_dqn_minus_uniform_rmse": float(np.mean(delta)),
            "dqn_lower_rmse_starts": int(sum(value < 0 for value in delta)),
            "mean_dqn_coverage_distance_m": float(np.mean([a["mean_grid_distance_to_cpt_m"] for a, _ in pairs])),
            "mean_uniform_coverage_distance_m": float(np.mean([b["mean_grid_distance_to_cpt_m"] for _, b in pairs])),
        }
    return {
        "protocol": "six-field-CPT-known-site-retrospective-pilot-v1",
        "scenario": SCENARIO,
        "field_profiles_sha256": sha256(root / "results/real_world_testing/real_cpt_ic_profiles.csv"),
        "field_metadata_sha256": sha256(root / "results/real_world_testing/real_cpt_metadata.json"),
        "field_metadata_coordinate_accuracy_verified": metadata["coordinate_reference"]["horizontal_accuracy_verified"],
        "schemaGAN_checkpoint_sha256": EXPECTED_SCHEMAGAN,
        "DQN_checkpoint_sha256": EXPECTED_DQN,
        "truth_scope": "six measured CPT profiles only; no whole-area ground truth",
        "candidate_scope": "only five other measured CPT sites per start, access masked",
        "common_mask": "same CPT profiles hidden from both policies at each stage",
        "independence_limit": "six starts reuse the same field site; exploratory, not independent trials",
        "summary": summary,
        "cases": rows,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--research-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = evaluate(args.research_root.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    main()
