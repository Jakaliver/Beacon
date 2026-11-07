"""Download and warm up every local model. Run once with internet access."""
import os
import shutil
import time

import numpy as np
from huggingface_hub import hf_hub_download, snapshot_download

from .config import DEPTH_CHECKPOINT, DEPTH_REPO, DETECTOR_BASE, DETECTOR_CHECKPOINT, MODELS_DIR, PARAKEET_MODEL


def main() -> None:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    if not DEPTH_CHECKPOINT.exists():
        path = hf_hub_download(DEPTH_REPO, DEPTH_CHECKPOINT.name)
        shutil.copy(path, DEPTH_CHECKPOINT)
    build_detector()
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


def build_detector() -> None:
    """Bake the prompt embeddings into the detector, so the server never needs the text model."""
    from ultralytics import YOLOE
    from .perception import prompts
    if DETECTOR_CHECKPOINT.exists() and list(YOLOE(str(DETECTOR_CHECKPOINT)).names.values()) == prompts():
        return
    cwd = os.getcwd()
    os.chdir(MODELS_DIR)  # Ultralytics downloads the weights and the 600 MB MobileCLIP model here
    try:
        model = YOLOE(DETECTOR_BASE)
        model.set_classes(prompts())
        model.save(DETECTOR_CHECKPOINT.name)
    finally:
        os.chdir(cwd)


if __name__ == "__main__":
    main()
