import os
from dataclasses import dataclass
from pathlib import Path

MAC_DIR = Path(__file__).resolve().parent.parent
MODELS_DIR = MAC_DIR / "models"
DA2_DIR = MAC_DIR / "third_party" / "Depth-Anything-V2"

DEPTH_CHECKPOINT = MODELS_DIR / "depth_anything_v2_metric_hypersim_vits.pth"
DEPTH_REPO = "depth-anything/Depth-Anything-V2-Metric-Hypersim-Small"
# YOLOE vocabulary cache keeps its existing filename across the product rename.
DETECTOR_BASE = "yoloe-11s-seg.pt"
DETECTOR_CHECKPOINT = MODELS_DIR / "yoloe-11s-seg-trident.pt"
PARAKEET_MODEL = os.environ.get("BEACON_PARAKEET", os.environ.get("TRIDENT_PARAKEET", "mlx-community/parakeet-tdt-0.6b-v3"))


@dataclass
class Config:
    memory_budget_mb: int = int(os.environ.get("BEACON_MEMORY_BUDGET_MB", os.environ.get("TRIDENT_MEMORY_BUDGET_MB", 16384)))
    # Room view updates per second. Only changed point clouds are sent, so faster Macs can go high.
    viewer_hz: float = float(os.environ.get("BEACON_VIEWER_HZ", os.environ.get("TRIDENT_VIEWER_HZ", 5)))
    depth_input_size: int = 518  # upstream default
    depth_max: float = 20.0
    detect_every_n_frames: int = 2

    map_size_m: float = 8.0
    cell_m: float = 0.1

    obstacle_min_h: float = 0.15  # above floor
    map_max_range_m: float = 4.0
    obstacle_max_h: float = 2.0
    floor_band: float = 0.08

    # Inflation terms for walking clearance (metres).
    body_radius: float = 0.22
    clearance_margin: float = 0.08
    hand_body_uncertainty: float = 0.08
    head_above_phone: float = 0.35  # approximate; real AirPods give no head position
    hand_forward_offset: float = 0.3  # phone held this far ahead of the torso while walking
    depth_uncertainty: float = 0.05
    latency_margin: float = 0.03

    approach_min: float = 0.35
    approach_max: float = 0.75
    probe_enter: float = 0.7  # horizontal phone-to-target distance
    probe_leave: float = 1.0  # listener drift that ends Probe mode

    near_m: float = 0.15
    far_m: float = 3.0
    confirm_min_m: float = 0.2

    offscreen_max_age_s: float = 30.0
    max_sigma_m: float = 0.35
    misses_to_lose: int = 8  # at most one miss per 0.5 s while the target should be visible
    sigma_growth_per_s: float = 0.01

    pose_timeout_s: float = 1.0
    # Touching the target covers the camera and ARKit limits tracking: within reach that is arrival,
    # so guidance pauses instead of stopping, unless it lasts this long.
    probe_limited_tracking_s: float = 10.0
    max_pose_latency_s: float = 0.5  # beyond the fastest pose seen this session
    walking_perception_timeout_s: float = 2.5

    @property
    def inflation_m(self) -> float:
        return (self.body_radius + self.clearance_margin + self.hand_body_uncertainty
                + self.depth_uncertainty + self.latency_margin)


CONFIG = Config()
