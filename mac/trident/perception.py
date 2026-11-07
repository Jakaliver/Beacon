"""Local vision models: Depth Anything V2 metric (Hypersim, ViT-S) and YOLO11n-seg."""
import sys
from dataclasses import dataclass

import numpy as np
import torch
import torch.nn.functional as F

from .config import CONFIG, DA2_DIR, DEPTH_CHECKPOINT, YOLO_CHECKPOINT

sys.path.insert(0, str(DA2_DIR / "metric_depth"))
from depth_anything_v2.dpt import DepthAnythingV2  # noqa: E402


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
        # Half precision on the GPU: twice as fast, depth within 0.2% of float32 (p99, measured).
        self.dtype = torch.float16 if self.device == "mps" else torch.float32
        self.depth_model = model.to(self.device, self.dtype).eval()

        from ultralytics import YOLO
        self.yolo = YOLO(str(YOLO_CHECKPOINT))
        self.labels: dict[int, str] = self.yolo.names

    @torch.inference_mode()
    def depth(self, bgr: np.ndarray) -> np.ndarray:
        """Metric depth in metres at the input image resolution."""
        image, (h, w) = self.depth_model.image2tensor(bgr, CONFIG.depth_input_size)
        depth = self.depth_model(image.to(self.dtype))[:, None].float()
        return F.interpolate(depth, (h, w), mode="bilinear", align_corners=True)[0, 0].cpu().numpy()

    def detect(self, bgr: np.ndarray) -> list[Detection]:
        # 960 px and a low threshold: real flasks scored 0.2-0.5 at best (about 2 ms extra on MPS).
        result = self.yolo.predict(bgr, imgsz=960, device=self.device, retina_masks=True,
                                   conf=0.15, verbose=False)[0]
        if result.masks is None:
            return []
        masks = result.masks.data.cpu().numpy() > 0.5
        out = []
        for i, box in enumerate(result.boxes):
            out.append(Detection(self.labels[int(box.cls)], float(box.conf),
                                 tuple(box.xyxy[0].tolist()), masks[i]))
        return out
