"""Local vision models: Depth Anything V2 metric (Hypersim, ViT-S) and open-vocabulary YOLOE-11s-seg."""
import sys
from dataclasses import dataclass

import numpy as np
import torch
import torch.nn.functional as F

from .config import CONFIG, DA2_DIR, DEPTH_CHECKPOINT, DETECTOR_CHECKPOINT

sys.path.insert(0, str(DA2_DIR / "metric_depth"))
from depth_anything_v2.dpt import DepthAnythingV2  # noqa: E402
from depth_anything_v2.dinov2_layers.attention import Attention  # noqa: E402
from .attention import use_native_attention

# Household targets COCO lacks, as detector prompt -> target label. Several wordings can name
# one target: on test photos "wall switch" and "switch plate" found switches that "light switch" missed.
EXTRA_PROMPTS = {
    "door": "door", "door handle": "door handle",
    "light switch": "light switch", "wall switch": "light switch", "switch plate": "light switch",
    "power outlet": "power outlet", "window": "window", "stairs": "stairs",
    "keys": "keys", "wallet": "wallet", "glasses": "glasses", "headphones": "headphones",
    "shoe": "shoe", "trash can": "trash can",
}


def prompts() -> list[str]:
    from ultralytics.utils import ROOT, YAML
    return [*YAML.load(ROOT / "cfg/datasets/coco.yaml")["names"].values(), *EXTRA_PROMPTS]


@dataclass
class Detection:
    label: str
    conf: float
    box: tuple[float, float, float, float]
    mask: np.ndarray  # bool, image resolution


class Perception:
    def __init__(self) -> None:
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        model = DepthAnythingV2(encoder="vits", features=64, out_channels=[48, 96, 192, 384],
                                max_depth=CONFIG.depth_max)
        model.load_state_dict(torch.load(DEPTH_CHECKPOINT, map_location="cpu"))
        use_native_attention(model, Attention)
        # Half precision on the GPU: twice as fast, depth within 0.2% of float32 (p99, measured).
        self.dtype = torch.float16 if self.device == "mps" else torch.float32
        self.depth_model = model.to(self.device, self.dtype).eval()

        from ultralytics import YOLOE
        self.yolo = YOLOE(str(DETECTOR_CHECKPOINT)) if DETECTOR_CHECKPOINT.exists() else None
        if self.yolo is None or list(self.yolo.names.values()) != prompts():
            raise RuntimeError("Detector vocabulary is missing or changed: run `uv run python -m beacon.setup_models`.")
        self.labels: dict[int, str] = {i: EXTRA_PROMPTS.get(p, p) for i, p in self.yolo.names.items()}

    @torch.inference_mode()
    def depth(self, bgr: np.ndarray) -> np.ndarray:
        """Metric depth in metres at the input image resolution."""
        image, (h, w) = self.depth_model.image2tensor(bgr, CONFIG.depth_input_size)
        depth = self.depth_model(image.to(self.dtype))[:, None].float()
        return F.interpolate(depth, (h, w), mode="bilinear", align_corners=True)[0, 0].cpu().numpy()

    def detect(self, bgr: np.ndarray) -> list[Detection]:
        # 960 px and a low threshold: real flasks scored 0.2-0.5 at best (about 2 ms extra on MPS).
        result = self.yolo.predict(bgr, imgsz=960, device=self.device, retina_masks=True, conf=0.15,
                                   verbose=False, quantize="fp16" if self.device == "mps" else None)[0]
        if result.masks is None:
            return []
        masks = result.masks.data.cpu().numpy() > 0.5
        out = []
        for i, box in enumerate(result.boxes):
            out.append(Detection(self.labels[int(box.cls)], float(box.conf),
                                 tuple(box.xyxy[0].tolist()), masks[i]))
        return out
