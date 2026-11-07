# Models and licences

`scripts/setup.sh` downloads everything below. Model weights and third-party code stay out of Git
(`mac/models/`, `mac/third_party/`). After setup, `scripts/dev.sh` runs
with `HF_HUB_OFFLINE=1` and `YOLO_OFFLINE=1`.

| Component | Source | Licence |
|---|---|---|
| Depth Anything V2 Metric Hypersim Small (`depth_anything_v2_metric_hypersim_vits.pth`, ViT-S, `max_depth=20`, input 518) | [depth-anything/Depth-Anything-V2-Metric-Hypersim-Small](https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Hypersim-Small) | Apache-2.0 (Small model) |
| Depth Anything V2 `metric_depth` code, commit `a561b84` | [DepthAnything/Depth-Anything-V2](https://github.com/DepthAnything/Depth-Anything-V2) | Apache-2.0 |
| YOLO11n-seg (`yolo11n-seg.pt`, COCO classes) | [Ultralytics](https://github.com/ultralytics/ultralytics) | **AGPL-3.0** (or an Ultralytics Enterprise licence) |
| Parakeet TDT 0.6B v3 via `parakeet-mlx` | [mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) | CC-BY-4.0 (model), Apache-2.0 (`parakeet-mlx`) |

Note the AGPL-3.0 terms of Ultralytics if you distribute Beacon or offer it as a network service.

Python dependencies are pinned in `mac/pyproject.toml` and `mac/uv.lock`. Web dependencies
are pinned in `web/package.json` and `web/package-lock.json`.
