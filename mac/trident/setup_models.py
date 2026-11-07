"""Download and warm up every local model. Run once with internet access."""
import shutil
import time

import numpy as np
from huggingface_hub import hf_hub_download, snapshot_download

from .config import DEPTH_CHECKPOINT, DEPTH_REPO, MODELS_DIR, PARAKEET_MODEL, YOLO_CHECKPOINT


def main() -> None:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    if not DEPTH_CHECKPOINT.exists():
        path = hf_hub_download(DEPTH_REPO, DEPTH_CHECKPOINT.name)
        shutil.copy(path, DEPTH_CHECKPOINT)
    if not YOLO_CHECKPOINT.exists():
        from ultralytics.utils.downloads import attempt_download_asset
        shutil.move(attempt_download_asset("yolo11n-seg.pt"), YOLO_CHECKPOINT)
    snapshot_download(PARAKEET_MODEL)

    from .perception import Perception
    from .speech import Speech

    t = time.time()
    perception = Perception()
    img = (np.random.rand(480, 640, 3) * 255).astype(np.uint8)
    for _ in range(2):
        perception.depth(img)
        perception.detect(img)
    print(f"vision warm-up ok on {perception.device} ({time.time() - t:.1f}s)")

    t = time.time()
    print("speech warm-up:", repr(Speech().transcribe_pcm(np.zeros(16000, np.float32), 16000)),
          f"({time.time() - t:.1f}s)")


if __name__ == "__main__":
    main()
