"""Local speech recognition with parakeet-mlx, plus the simple command parser."""
import io
import re
import wave

import mlx.core as mx
import numpy as np

from .config import PARAKEET_MODEL


class Speech:
    def __init__(self) -> None:
        from parakeet_mlx import from_pretrained
        self.model = from_pretrained(PARAKEET_MODEL)
        self.rate = self.model.preprocessor_config.sample_rate

    def transcribe_wav(self, data: bytes) -> str:
        with wave.open(io.BytesIO(data)) as w:
            if w.getsampwidth() != 2:
                raise ValueError("expected 16-bit PCM WAV")
            pcm = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
            pcm = pcm.reshape(-1, w.getnchannels()).mean(axis=1)
            return self.transcribe_pcm(pcm, w.getframerate())

    def transcribe_pcm(self, pcm: np.ndarray, rate: int) -> str:
        # A quick press/release can send an empty or sub-word clip. Parakeet's
        # spectral window cannot process these; let the phone ask for a request.
        if len(pcm) < rate * 0.1:
            return ""
        if rate != self.rate:
            n = int(len(pcm) * self.rate / rate)
            pcm = np.interp(np.linspace(0, len(pcm) - 1, n), np.arange(len(pcm)), pcm)
        pcm = pcm[: self.rate * 15]  # short push-to-talk clips only
        from parakeet_mlx.audio import get_logmel
        mel = get_logmel(mx.array(pcm.astype(np.float32)),
                         self.model.preprocessor_config)
        return self.model.generate(mel)[0].text.strip()


# Spoken words → YOLO (COCO) class names.
SYNONYMS = {
    "bottle": "bottle", "water bottle": "bottle", "waterbottle": "bottle", "flask": "bottle", "thermos": "bottle", "water": "bottle", "drink": "bottle",
    "cup": "cup", "mug": "cup", "glass": "cup", "teacup": "cup", "coffee": "cup",
    "chair": "chair", "seat": "chair", "stool": "chair",
    "sofa": "couch", "couch": "couch", "settee": "couch",
    "table": "dining table", "desk": "dining table",
    "plant": "potted plant", "laptop": "laptop", "computer": "laptop",
    "phone": "cell phone", "mobile": "cell phone", "book": "book", "bowl": "bowl",
    "remote": "remote", "keyboard": "keyboard", "mouse": "mouse", "bag": "handbag",
    "backpack": "backpack", "umbrella": "umbrella", "clock": "clock", "vase": "vase",
    "tv": "tv", "television": "tv", "bed": "bed", "person": "person", "scissors": "scissors",
    "toilet": "toilet", "sink": "sink", "banana": "banana", "apple": "apple", "orange": "orange",
}
WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "first": 1, "second": 2, "third": 3}


def parse_command(text: str, labels: set[str]) -> dict:
    t = re.sub(r"[^a-z0-9 ]", " ", text.lower()).strip()
    t = re.sub(r"\s+", " ", t)
    for verb in ("stop", "cancel", "repeat", "inspect", "resume", "calibrate"):
        if re.search(rf"\b{verb}\b", t):
            return {"cmd": verb}
    if m := re.search(r"\b(?:choose|pick|option|number)\s+(?:number\s+)?(\w+)", t):
        n = WORDS.get(m.group(1)) or (int(m.group(1)) if m.group(1).isdigit() else None)
        if n:
            return {"cmd": "choose", "index": n}
    if m := re.search(r"\bnavigation (on|off)\b", t):
        return {"cmd": "navigation", "on": m.group(1) == "on"}
    if m := re.search(r"\b(?:find|where is|where s|locate|look for|search for|get)\b(.*)", t):
        obj = re.sub(r"\b(the|a|an|my|me|some|please)\b", " ", m.group(1)).strip()
        obj = re.sub(r"\s+", " ", obj).rstrip("s") if obj not in SYNONYMS else obj
        label = SYNONYMS.get(obj) or SYNONYMS.get(obj.split(" ")[-1] if obj else "")
        if not label and obj in labels:
            label = obj
        if label and label in labels:
            return {"cmd": "find", "label": label, "spoken": obj}
        return {"cmd": "unsupported", "spoken": obj}
    return {"cmd": "unknown", "spoken": t}


if __name__ == "__main__":
    labels = {"bottle", "cup", "chair", "couch", "dining table"}
    assert parse_command("Find the bottle.", labels) == {"cmd": "find", "label": "bottle", "spoken": "bottle"}
    assert parse_command("find my mugs", labels)["label"] == "cup"
    assert parse_command("Find waterbottle", labels)["label"] == "bottle"
    assert parse_command("find the water bottle", labels)["label"] == "bottle"
    assert parse_command("Find the sofa", labels)["label"] == "couch"
    assert parse_command("find a giraffe", labels)["cmd"] == "unsupported"
    assert parse_command("Stop!", labels) == {"cmd": "stop"}
    assert parse_command("choose number two", labels) == {"cmd": "choose", "index": 2}
    assert parse_command("choose 1", labels) == {"cmd": "choose", "index": 1}
    print("parse_command ok")
