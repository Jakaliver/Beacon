# Models and licences

Beacon's original source code and documentation use
[AGPL-3.0-only](../LICENSE). Third-party code and model weights are governed by their
respective licences below; the project licence does not grant additional rights to them.

`scripts/setup.sh` downloads everything below. Model weights and third-party code stay out of Git
(`mac/models/`, `mac/third_party/`). After setup, `scripts/dev.sh` runs
with `HF_HUB_OFFLINE=1` and `YOLO_OFFLINE=1`.

| Component | Source | Licence |
|---|---|---|
| Depth Anything V2 Metric Hypersim Small (`depth_anything_v2_metric_hypersim_vits.pth`, ViT-S, `max_depth=20`, input 518) | [depth-anything/Depth-Anything-V2-Metric-Hypersim-Small](https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Hypersim-Small) | Apache-2.0 (Small model) |
| Depth Anything V2 `metric_depth` code, commit `a561b84` | [DepthAnything/Depth-Anything-V2](https://github.com/DepthAnything/Depth-Anything-V2) | Apache-2.0 |
| YOLOE-11s-seg (`yoloe-11s-seg.pt`), saved with Trident's prompt vocabulary as `yoloe-11s-seg-trident.pt` | [Ultralytics](https://github.com/ultralytics/ultralytics) | **AGPL-3.0** (or an Ultralytics Enterprise licence) |
| MobileCLIP text encoder (`mobileclip_blt.ts`), used only by `setup_models` to embed the prompts | [Ultralytics assets](https://github.com/ultralytics/assets), from [apple/ml-mobileclip](https://github.com/apple/ml-mobileclip) | MIT for upstream code; separate [Apple Machine Learning Research Model licence](https://huggingface.co/apple/MobileCLIP-B-LT/blob/main/LICENSE) for the upstream model |
| NVIDIA Parakeet TDT 0.6B v3, converted to MLX by MLX Community, via `parakeet-mlx` | [mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) | CC-BY-4.0 (model), Apache-2.0 (`parakeet-mlx`) |

AGPL-3.0 is the project's source-code licence to align with the
[Ultralytics open-source licensing option](https://www.ultralytics.com/license).
Follow its corresponding-source obligations when distributing covered software or
running a modified version as a network service.

The upstream MobileCLIP-B-LT model licence limits use to non-commercial scientific
research and academic development, excluding commercial exploitation and product
development. Downloading an exported copy from another provider does not establish
additional permission. Confirm the exact encoder's provenance and applicable terms,
obtain suitable permission or replace it before using this pipeline outside that scope.
The repository does not redistribute model weights or claim that they are AGPL-licensed.

If redistributing dependencies or model files, include their required licence texts,
copyright notices and attributions. Preserve NVIDIA/MLX Community attribution for
Parakeet, link its CC-BY-4.0 terms and identify any changes to the model.

Python dependencies are pinned in `mac/pyproject.toml` and `mac/uv.lock`. Web dependencies
are pinned in `web/package.json` and `web/package-lock.json`.
