#!/usr/bin/env python3
"""Offline study of the per-query visual threshold.

Reproduces the evidence for `SearchConfig.relativeThreshold*`. It embeds the
local Flickr30k soak photos with the pinned reference SigLIP2 model, labels
short everyday queries from the photo captions, and compares the fixed cutoff
with the relative rule over many random library sizes.

Caption labels are incomplete, so an unlabeled but correct photo counts
against precision. Compare rules with each other rather than reading the
numbers as absolute quality.

Requires torch and transformers. The model is downloaded from the pinned
public revision; no application code, user media or review context is sent.
Photos come from the gitignored `.relevance-cache/soak-flickr30k-10k`.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".relevance-cache"
SOAK = CACHE / "soak-flickr30k-10k"
EMBEDDINGS = CACHE / "visual-threshold-study" / "flickr-embeddings.npy"
MODEL = "google/siglip2-base-patch16-224"
REVISION = "75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2"

# Query -> caption patterns that must all match for a photo to be relevant.
POSITIVE_QUERIES = {
    "dog": [r"\bdogs?\b|\bpupp(y|ies)\b"], "cat": [r"\bcats?\b|\bkittens?\b"],
    "horse": [r"\bhorses?\b"], "bicycle": [r"\bbikes?\b|\bbicycl|\bcyclists?\b|\bbiking\b"],
    "car": [r"\bcars?\b"], "beach": [r"\bbeach"], "snow": [r"\bsnow"],
    "waterfall": [r"waterfall"], "flowers": [r"\bflowers?\b"], "guitar": [r"guitar"],
    "baby": [r"\bbab(y|ies)\b|\binfants?\b"], "wedding": [r"wedding|\bbrides?\b"],
    "boat": [r"\bboats?\b|kayak|canoe"], "mountain": [r"\bmountain"],
    "soccer": [r"soccer"], "basketball": [r"basketball"], "skateboard": [r"skateboard"],
    "surfing": [r"\bsurf"], "fire": [r"\bfire\b|\bflames?\b"], "bus": [r"\bbus\b|\bbuses\b"],
    "train": [r"\btrains?\b"], "kitchen": [r"kitchen"], "cake": [r"\bcakes?\b"],
    "umbrella": [r"umbrella"], "graffiti": [r"graffiti"],
    "motorcycle": [r"motorcycl|motorbike|dirt bike"], "balloons": [r"balloon"],
    "statue": [r"statue"], "bridge": [r"\bbridge"], "sunset": [r"sunset"],
    "fireworks": [r"firework"], "tattoo": [r"tattoo"],
    "pink flowers": [r"\bflowers?\b", r"\bpink\b"], "red car": [r"\bcars?\b", r"\bred\b"],
    "black dog": [r"\bdogs?\b", r"\bblack\b"], "man playing guitar": [r"guitar", r"\bman\b"],
    "children in a park": [r"\bchild|\bkids?\b|\bboys\b|\bgirls\b", r"\bpark\b"],
    "horse riding": [r"\bhorses?\b", r"\brid(e|es|ing|er)\b"],
    "snowboarding": [r"snowboard"], "rock climbing": [r"climb"],
}
# Subjects absent from the soak captions. Inspect any hit before trusting it:
# the study found real polar bears that the caption filter missed.
NO_ANSWER_QUERIES = [
    "purple unicorn submarine", "quantum marmalade observatory",
    "zxqv purple elephant spaceship", "astronaut on the moon", "volcano erupting",
    "dinosaur skeleton", "aurora borealis", "penguin colony", "giraffe",
    "space shuttle launch", "lighthouse at night", "blorft wemble", "tax return spreadsheet",
]
FIXED_THRESHOLD = 0.12


def load_model():
    from transformers import AutoModel, AutoTokenizer

    model = AutoModel.from_pretrained(MODEL, revision=REVISION).eval()
    return model, AutoTokenizer.from_pretrained(MODEL, revision=REVISION)


def embed_photos(model, metadata) -> None:
    import numpy as np
    import torch
    from PIL import Image, ImageOps

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model = model.to(device)
    vectors = []
    for start in range(0, len(metadata), 64):
        pixels = []
        for row in metadata[start:start + 64]:
            image = ImageOps.exif_transpose(Image.open(SOAK / "images" / row["local_filename"]))
            # SigLIP reference preprocessing: the whole image, resized.
            array = np.asarray(image.convert("RGB").resize((224, 224), Image.BILINEAR), dtype=np.float32)
            pixels.append(((array / 255.0 - 0.5) / 0.5).transpose(2, 0, 1))
        with torch.no_grad():
            output = model.get_image_features(pixel_values=torch.from_numpy(np.stack(pixels)).to(device))
            output = getattr(output, "pooler_output", output)
        vectors.append(torch.nn.functional.normalize(output, dim=-1).cpu().numpy())
        print(f"embedded {min(start + 64, len(metadata))}/{len(metadata)}", flush=True)
    EMBEDDINGS.parent.mkdir(parents=True, exist_ok=True)
    np.save(EMBEDDINGS, np.concatenate(vectors))


def embed_queries(model, tokenizer, queries):
    import torch

    model = model.to("cpu")
    # Match the app: lowercase, no BOS, EOS, padded to 64 tokens.
    ids = tokenizer([q.lower() for q in queries], padding="max_length", max_length=64, return_tensors="pt")
    with torch.no_grad():
        output = model.get_text_features(input_ids=ids["input_ids"])
        output = getattr(output, "pooler_output", output)
    return dict(zip(queries, torch.nn.functional.normalize(output, dim=-1).numpy()))


def relative_threshold(scores, multiplier, floor, minimum_sample):
    """Mirror of VisualMatchThresholdPolicy.threshold in SearchRanking.swift."""
    import numpy as np

    if len(scores) < minimum_sample:
        return FIXED_THRESHOLD
    median = float(np.median(scores))
    spread = float(np.median(np.abs(scores - median))) * 1.4826
    if spread <= 0:
        return FIXED_THRESHOLD
    return min(FIXED_THRESHOLD, max(floor, median + multiplier * spread))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--multipliers", default="5.5,6,6.5,7")
    parser.add_argument("--floor", type=float, default=0.09)
    parser.add_argument("--minimum-sample", type=int, default=20)
    args = parser.parse_args()

    import numpy as np

    if not (SOAK / "image-metadata.jsonl").exists():
        print(f"visual_threshold_study: missing {SOAK}", file=sys.stderr)
        return 1
    metadata = [json.loads(line) for line in (SOAK / "image-metadata.jsonl").open()]
    model, tokenizer = load_model()
    if not EMBEDDINGS.exists():
        embed_photos(model, metadata)
    photos = np.load(EMBEDDINGS)
    captions = [row["caption"].lower() for row in metadata]
    labels = {
        query: np.array([all(re.search(p, c) for p in patterns) for c in captions])
        for query, patterns in POSITIVE_QUERIES.items()
    }
    queries = embed_queries(model, tokenizer, list(POSITIVE_QUERIES) + NO_ANSWER_QUERIES)
    multipliers = [float(value) for value in args.multipliers.split(",")]

    for size, trials in ((20, 60), (50, 60), (200, 20), (1000, 10), (5000, 3)):
        totals = {rule: [0, 0, 0, 0, 0] for rule in ["fixed"] + multipliers}
        for trial in range(trials):
            rows = np.random.default_rng(100 + trial).choice(len(photos), size, replace=False)
            library = photos[rows]
            for query, vector in queries.items():
                scores = library @ vector
                for rule, total in totals.items():
                    cutoff = FIXED_THRESHOLD if rule == "fixed" else relative_threshold(
                        scores, rule, args.floor, args.minimum_sample
                    )
                    accepted = np.argsort(-scores)[: min(int((scores >= cutoff).sum()), 50)]
                    if query in NO_ANSWER_QUERIES:
                        total[4] += int(len(accepted) > 0)
                    elif labels[query][rows].any():
                        relevant = labels[query][rows][accepted]
                        total[0] += int(relevant.any())
                        total[1] += 1
                        total[2] += int(relevant.sum())
                        total[3] += len(accepted)
        print(f"\nLibrary of {size} photos, {trials} random libraries")
        print(f"{'rule':<14}{'found':>8}{'precision':>11}{'no-answer results':>19}")
        for rule, (hit, positives, relevant, shown, alarms) in totals.items():
            name = "fixed 0.12" if rule == "fixed" else f"relative k={rule}"
            precision = relevant / shown if shown else float("nan")
            alarm_rate = alarms / (trials * len(NO_ANSWER_QUERIES))
            print(f"{name:<14}{hit / positives:>8.2f}{precision:>11.2f}{alarm_rate:>19.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
