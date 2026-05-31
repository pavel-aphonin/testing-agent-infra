"""PER-198: perception microservice — Screen Parser / Dynamic Perceiver /
Context Identifier behind one FastAPI app.

Runs as a HOST process (not Docker) so it can use Apple Metal (MPS) —
same deployment shape as the host llama-server processes. One process,
three logical endpoints, each backed by its own model per the PER-175
roster:

  POST /classify  → Context Identifier  (DeBERTa-v3 zero-shot)
  POST /compare   → Dynamic Perceiver   (SigLIP2 embedding cosine)
  POST /parse     → Screen Parser       (OmniParser-v2, lazy)
  GET  /health    → readiness

Models load lazily on first use so the service boots instantly and a
missing-dep for one model (e.g. OmniParser's ultralytics) doesn't block
the other two. Each loader is memoised.
"""

from __future__ import annotations

import base64
import io
import logging
import os
from functools import lru_cache
from typing import Any

import torch
from fastapi import FastAPI
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("perception")

MODELS_ROOT = os.environ.get(
    "PERCEPTION_MODELS_ROOT",
    "/Users/pavelafonin/Projects/AI/testing-agent-infra/volumes/perception-models",
)

# Apple Silicon → MPS, else CPU. (CUDA path kept for Linux deploy.)
def _pick_device() -> str:
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


DEVICE = _pick_device()
logger.info("Perception service device: %s", DEVICE)

app = FastAPI(title="Perception microservice (PER-198)", version="0.1.0")


# ─────────────────────────────────────────────────────────────────────
# Context Identifier — DeBERTa-v3 zero-shot
# ─────────────────────────────────────────────────────────────────────

# Default candidate screen types for a banking app. Caller can override
# per request. Russian + English labels — the zero-shot model handles
# both; the worker passes whatever taxonomy it wants.
DEFAULT_SCREEN_LABELS = [
    "PIN code entry screen",
    "login or phone number entry screen",
    "SMS or OTP confirmation screen",
    "home or main dashboard screen",
    "money transfer or payment screen",
    "transaction history screen",
    "settings screen",
    "notification permission dialog",
    "error or warning dialog",
    "loading or splash screen",
]


@lru_cache(maxsize=1)
def _context_pipeline():
    from transformers import pipeline
    path = f"{MODELS_ROOT}/context-identifier"
    logger.info("Loading Context Identifier (DeBERTa zero-shot) from %s", path)
    # device index: pipeline wants -1 for CPU, 0 for cuda; for MPS we
    # pass the torch device string via device kwarg in recent transformers.
    dev = 0 if DEVICE == "cuda" else (-1 if DEVICE == "cpu" else DEVICE)
    return pipeline("zero-shot-classification", model=path, tokenizer=path, device=dev)


class ClassifyRequest(BaseModel):
    text: str  # screen description (OCR + element labels concatenated)
    candidate_labels: list[str] | None = None


class ClassifyResponse(BaseModel):
    label: str
    confidence: float
    all_scores: dict[str, float]


@app.post("/classify", response_model=ClassifyResponse)
def classify(req: ClassifyRequest) -> ClassifyResponse:
    labels = req.candidate_labels or DEFAULT_SCREEN_LABELS
    clf = _context_pipeline()
    result = clf(req.text, labels, multi_label=False)
    # transformers returns {labels: [...], scores: [...]} sorted desc
    top_label = result["labels"][0]
    top_score = float(result["scores"][0])
    return ClassifyResponse(
        label=top_label,
        confidence=top_score,
        all_scores={l: float(s) for l, s in zip(result["labels"], result["scores"])},
    )


# ─────────────────────────────────────────────────────────────────────
# Dynamic Perceiver — SigLIP2 embedding cosine
# ─────────────────────────────────────────────────────────────────────

@lru_cache(maxsize=1)
def _siglip():
    from transformers import AutoModel, AutoProcessor
    path = f"{MODELS_ROOT}/dynamic-perceiver"
    logger.info("Loading Dynamic Perceiver (SigLIP2) from %s", path)
    model = AutoModel.from_pretrained(path).to(DEVICE).eval()
    processor = AutoProcessor.from_pretrained(path)
    return model, processor


def _img_embed(img_bytes: bytes) -> torch.Tensor:
    from PIL import Image
    model, processor = _siglip()
    img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
    inputs = processor(images=img, return_tensors="pt").to(DEVICE)
    with torch.no_grad():
        feats = model.get_image_features(**inputs)
    # transformers 5.x can return either a tensor or an output object
    # depending on the model class — normalise to a 2D tensor.
    if not isinstance(feats, torch.Tensor):
        for attr in ("pooler_output", "image_embeds", "last_hidden_state"):
            val = getattr(feats, attr, None)
            if isinstance(val, torch.Tensor):
                feats = val
                break
        else:
            feats = feats[0]
        # last_hidden_state is [batch, seq, dim] — mean-pool to [batch, dim]
        if feats.dim() == 3:
            feats = feats.mean(dim=1)
    return torch.nn.functional.normalize(feats, dim=-1)


class CompareRequest(BaseModel):
    before_png_b64: str
    after_png_b64: str
    # cosine below this → "changed". 0.98 is a good default for "same
    # screen, maybe minor animation"; tune per app.
    changed_threshold: float = 0.98


class CompareResponse(BaseModel):
    similarity: float
    changed: bool


@app.post("/compare", response_model=CompareResponse)
def compare(req: CompareRequest) -> CompareResponse:
    before = _img_embed(base64.b64decode(req.before_png_b64))
    after = _img_embed(base64.b64decode(req.after_png_b64))
    sim = float((before @ after.T).item())
    return CompareResponse(similarity=sim, changed=sim < req.changed_threshold)


# ─────────────────────────────────────────────────────────────────────
# Vision screen-type classification — SigLIP2 zero-shot (PER-175 Phase B)
# ─────────────────────────────────────────────────────────────────────
#
# The blindness fix. The old Context Identifier classified screen TYPE
# from AX-tree TEXT (DeBERTa), which is empty on canvas/Flutter screens
# (run cccc3333: a PIN keypad read as "money transfer"). SigLIP2 matches
# the SCREENSHOT against candidate type descriptions — it sees the keypad.
#
# SigLIP uses a sigmoid image-text objective; for picking the best label
# we rank by image·text cosine and also return a calibrated 0..1 score so
# the caller can gate on confidence.

def _text_embed(labels: list[str]) -> torch.Tensor:
    model, processor = _siglip()
    inputs = processor(
        text=labels, return_tensors="pt", padding="max_length", truncation=True
    ).to(DEVICE)
    with torch.no_grad():
        feats = model.get_text_features(**inputs)
    if not isinstance(feats, torch.Tensor):
        for attr in ("pooler_output", "text_embeds", "last_hidden_state"):
            val = getattr(feats, attr, None)
            if isinstance(val, torch.Tensor):
                feats = val
                break
        else:
            feats = feats[0]
        if feats.dim() == 3:
            feats = feats.mean(dim=1)
    return torch.nn.functional.normalize(feats, dim=-1)


# Screen-type taxonomy as natural-language descriptions SigLIP can match a
# screenshot against. Returned ``screen_type`` is the short key (left of
# the colon); the description (right) is what's embedded. RU+EN phrasing
# because the app under test is Russian. Caller may override.
DEFAULT_SCREEN_TYPES: dict[str, str] = {
    "pin_entry": "a numeric PIN code entry screen with an on-screen keypad of digit buttons",
    "sms_entry": "a screen to enter an SMS one-time confirmation code",
    "login": "a login screen with a phone number or username input field",
    "password_entry": "a screen with a password input field",
    "home": "the main home dashboard screen of a banking app",
    "payment": "a money transfer or payment screen",
    "transactions": "a list of transactions or operation history",
    "settings": "an app settings screen",
    "permission_dialog": "a system permission dialog asking to allow access",
    "error_dialog": "an error or warning dialog box",
    "loading": "a loading or splash screen",
}


class ClassifyVisionRequest(BaseModel):
    png_b64: str
    # optional override: {short_key: natural-language description}
    candidate_types: dict[str, str] | None = None


class ClassifyVisionResponse(BaseModel):
    screen_type: str          # short key, e.g. "pin_entry"
    confidence: float         # 0..1, softmax over matched labels
    all_scores: dict[str, float]


@app.post("/classify_vision", response_model=ClassifyVisionResponse)
def classify_vision(req: ClassifyVisionRequest) -> ClassifyVisionResponse:
    types = req.candidate_types or DEFAULT_SCREEN_TYPES
    keys = list(types.keys())
    descriptions = [types[k] for k in keys]

    img = _img_embed(base64.b64decode(req.png_b64))   # [1, dim], normalized
    txt = _text_embed(descriptions)                    # [N, dim], normalized
    sims = (img @ txt.T).squeeze(0)                     # [N] cosine sims
    # softmax for a calibrated, comparable confidence across labels
    probs = torch.softmax(sims, dim=-1)
    best = int(torch.argmax(probs).item())
    all_scores = {keys[i]: float(probs[i].item()) for i in range(len(keys))}
    return ClassifyVisionResponse(
        screen_type=keys[best],
        confidence=float(probs[best].item()),
        all_scores=all_scores,
    )


# ─────────────────────────────────────────────────────────────────────
# Screen Parser — OmniParser-v2 (lazy; heavy deps)
# ─────────────────────────────────────────────────────────────────────

@lru_cache(maxsize=1)
def _omniparser():
    """Load OmniParser-v2 YOLOv8 icon detector + Florence-2 captioner.

    Heavy (ultralytics AGPL + Florence-2 + easyocr). Lazy so /classify
    and /compare work even if these deps aren't installed yet.
    """
    from ultralytics import YOLO
    root = f"{MODELS_ROOT}/screen-parser"
    logger.info("Loading Screen Parser (OmniParser-v2 YOLO) from %s", root)
    yolo = YOLO(f"{root}/icon_detect/model.pt")
    return yolo


class ParseRequest(BaseModel):
    png_b64: str
    box_threshold: float = 0.05


class ParsedElement(BaseModel):
    bbox: list[float]  # [x1, y1, x2, y2] normalized 0..1
    confidence: float


class ParseResponse(BaseModel):
    elements: list[ParsedElement]
    count: int


@app.post("/parse", response_model=ParseResponse)
def parse(req: ParseRequest) -> ParseResponse:
    from PIL import Image
    yolo = _omniparser()
    img = Image.open(io.BytesIO(base64.b64decode(req.png_b64))).convert("RGB")
    w, h = img.size
    results = yolo.predict(img, conf=req.box_threshold, verbose=False)
    elements: list[ParsedElement] = []
    for r in results:
        for box in r.boxes:
            x1, y1, x2, y2 = box.xyxy[0].tolist()
            elements.append(ParsedElement(
                bbox=[x1 / w, y1 / h, x2 / w, y2 / h],
                confidence=float(box.conf[0]),
            ))
    return ParseResponse(elements=elements, count=len(elements))


# ─────────────────────────────────────────────────────────────────────

@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "device": DEVICE}
