import datetime
import hashlib
import json
import os
import time

import cv2
import numpy as np
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from insightface.app import FaceAnalysis
from sqlalchemy.orm import Session
from starlette.middleware.sessions import SessionMiddleware

import models
import schemas
from database import engine, get_db
from admin_router import router as admin_router

# ── Model directory ─────────────────────────────────────────────────────────────
# Models are mounted at /app/models — same volume as InsightFace weights.
# The two ONNX files for the Flutter SDK live here:
#   /app/models/minifasnet.onnx
#   /app/models/mobilefacenet.onnx
_MODELS_DIR = os.environ.get("MODELS_DIR", "./models")
_ALLOWED_MODELS = {"minifasnet.onnx", "mobilefacenet.onnx"}

# ── DB bootstrap ────────────────────────────────────────────────────────────────
models.Base.metadata.create_all(bind=engine)

# ── App ─────────────────────────────────────────────────────────────────────────
app = FastAPI(title="Liveness & Face Auth Backend")

app.add_middleware(
    SessionMiddleware,
    secret_key=os.environ.get("SESSION_SECRET", "change-me-in-production"),
    https_only=False,   # set True behind HTTPS in production
)

app.include_router(admin_router)

# Redirect root → admin
@app.get("/", include_in_schema=False)
async def root():
    return RedirectResponse("/admin/keys")


# ── InsightFace models ──────────────────────────────────────────────────────────
# Full image pipeline: large det_size for detection across the whole frame
face_app = FaceAnalysis(
    name="buffalo_l", root="./models", providers=["CPUExecutionProvider"]
)
face_app.prepare(ctx_id=0, det_size=(640, 640))

# Pre-cropped face pipeline: small det_size matched to a face-filling crop
face_app_cropped = FaceAnalysis(
    name="buffalo_l", root="./models", providers=["CPUExecutionProvider"]
)
face_app_cropped.prepare(ctx_id=0, det_size=(128, 128))


# ── Utilities ───────────────────────────────────────────────────────────────────

def compute_similarity(feat1, feat2):
    return np.dot(feat1, feat2) / (np.linalg.norm(feat1) * np.linalg.norm(feat2))


def verify_api_key(api_key: str, db: Session) -> models.APIKey:
    db_key = db.query(models.APIKey).filter(models.APIKey.key == api_key).first()
    if not db_key or not db_key.is_active:
        raise HTTPException(status_code=401, detail="Invalid or inactive API Key")
    if db_key.expires_at and db_key.expires_at < datetime.datetime.utcnow():
        raise HTTPException(status_code=401, detail="API Key has expired")
    return db_key


def get_embedding_from_image(
    img_bgr: np.ndarray, is_cropped: bool, label: str = "img"
) -> np.ndarray | None:
    """Extract face embedding.

    If already cropped, resize to 112×112 and run with small-det_size model.
    If full image, run detection with the full-resolution model.
    """
    # --- DEBUG: Save received image ---
    debug_dir = "/tmp/debug"
    os.makedirs(debug_dir, exist_ok=True)
    ts = int(time.time() * 1000)
    orig_path = f"{debug_dir}/{label}_original_{ts}.jpg"
    cv2.imwrite(orig_path, img_bgr)
    print(f"[DEBUG] Saved {label} original ({img_bgr.shape}) => {orig_path}")
    # ----------------------------------

    if is_cropped:
        resized = cv2.resize(img_bgr, (112, 112))
        resized_path = f"{debug_dir}/{label}_resized_112_{ts}.jpg"
        cv2.imwrite(resized_path, resized)
        print(f"[DEBUG] Saved {label} resized 112x112 => {resized_path}")
        faces = face_app_cropped.get(resized)
        if not faces:
            print(f"[DEBUG] InsightFace (det_size=128) found NO faces in {label}")
            return None
        print(f"[DEBUG] InsightFace (det_size=128) found {len(faces)} face(s) in {label}")
        return faces[0].embedding
    else:
        faces = face_app.get(img_bgr)
        if not faces:
            print(f"[DEBUG] InsightFace (det_size=640) found NO faces in {label}")
            return None
        print(f"[DEBUG] InsightFace (det_size=640) found {len(faces)} face(s) in {label}")
        return faces[0].embedding


# ── API endpoints ───────────────────────────────────────────────────────────────

@app.get("/validate_key", include_in_schema=False)  # convenience redirect for browsers
async def validate_key_get():
    return RedirectResponse("/admin/keys")


@app.post("/validate_key", response_model=schemas.ValidateKeyResponse)
def validate_key(request: schemas.ValidateKeyRequest, db: Session = Depends(get_db)):
    db_key = db.query(models.APIKey).filter(models.APIKey.key == request.api_key).first()

    if not db_key:
        return {"is_valid": False, "message": "API Key not found"}
    if not db_key.is_active:
        return {"is_valid": False, "message": "API Key is inactive"}
    if db_key.expires_at and db_key.expires_at < datetime.datetime.utcnow():
        return {"is_valid": False, "message": "API Key has expired"}

    return {"is_valid": True, "expires_at": db_key.expires_at}


# ── Model distribution ────────────────────────────────────────────────────────

def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


@app.get("/models/manifest")
def models_manifest(
    api_key: str,
    db: Session = Depends(get_db),
):
    """Returns name + sha256 + size_bytes for each available ONNX model.
    Clients use this to decide whether a cached copy is still current."""
    verify_api_key(api_key, db)
    manifest = {}
    for name in _ALLOWED_MODELS:
        path = os.path.join(_MODELS_DIR, name)
        if os.path.isfile(path):
            manifest[name] = {
                "sha256": _sha256(path),
                "size_bytes": os.path.getsize(path),
            }
    return JSONResponse(manifest)


@app.get("/models/download/{filename}")
def download_model(
    filename: str,
    api_key: str,
    db: Session = Depends(get_db),
):
    """Streams an ONNX model file to authenticated SDK clients."""
    verify_api_key(api_key, db)
    if filename not in _ALLOWED_MODELS:
        raise HTTPException(status_code=404, detail="Model not found")
    path = os.path.join(_MODELS_DIR, filename)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="Model file missing on server")
    return FileResponse(
        path,
        media_type="application/octet-stream",
        filename=filename,
    )


@app.post("/compare_faces")
async def compare_faces(
    api_key: str = Form(...),
    cropped: bool = Form(True),
    reference_image: UploadFile = File(...),
    target_image: UploadFile = File(...),
    threshold: float = Form(0.7),
    db: Session = Depends(get_db),
):
    verify_api_key(api_key, db)

    ref_bytes = await reference_image.read()
    tgt_bytes = await target_image.read()

    ref_img = cv2.imdecode(np.frombuffer(ref_bytes, np.uint8), cv2.IMREAD_COLOR)
    tgt_img = cv2.imdecode(np.frombuffer(tgt_bytes, np.uint8), cv2.IMREAD_COLOR)

    if ref_img is None or tgt_img is None:
        raise HTTPException(status_code=400, detail="Could not decode one or both images.")

    ref_feat = get_embedding_from_image(ref_img, cropped, label="ref")
    tgt_feat = get_embedding_from_image(tgt_img, cropped, label="tgt")

    if ref_feat is None or tgt_feat is None:
        return {
            "success": False,
            "message": "Face not detected in one or both images.",
            "similarity_score": 0.0,
            "threshold_met": False,
        }

    similarity = compute_similarity(ref_feat, tgt_feat)
    is_match = bool(similarity >= threshold)

    return {
        "success": is_match,
        "similarity_score": float(similarity),
        "threshold_met": is_match,
        "message": "Verification successful" if is_match else "Faces do not match",
        "cropped_processed": cropped,
    }


@app.post("/sync_logs")
def sync_logs(request: schemas.SyncLogsRequest, db: Session = Depends(get_db)):
    verify_api_key(request.api_key, db)

    inserted = 0
    for log_entry in request.logs:
        db_log = models.APILog(
            timestamp=log_entry.timestamp,
            user_id=str(log_entry.user_id) if log_entry.user_id else None,
            request_id=log_entry.request_id,
            device_id=log_entry.device_id,
            method=log_entry.method,
            execution_mode=log_entry.execution_mode,
            parameters=json.dumps(log_entry.parameters) if log_entry.parameters else None,
            result=json.dumps(log_entry.result) if log_entry.result else None,
            errors=json.dumps(log_entry.errors) if log_entry.errors else None,
        )
        db.add(db_log)
        inserted += 1

    db.commit()
    return {"success": True, "logs_synced": inserted}
