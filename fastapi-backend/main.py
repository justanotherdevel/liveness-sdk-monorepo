from fastapi import FastAPI, Depends, HTTPException, status, File, UploadFile, Form
from sqlalchemy.orm import Session
import models, schemas
from database import engine, get_db
import datetime
import json
import cv2
import numpy as np
from insightface.app import FaceAnalysis

models.Base.metadata.create_all(bind=engine)

app = FastAPI(title="Liveness & Face Auth Backend")

# Initialize InsightFace Buffalo Large Model
# Expects models in ./models/models/buffalo_l/ 
# OR just ./models/buffalo_l/ based on Insightface version
face_app = FaceAnalysis(name='buffalo_l', root='./models', providers=['CPUExecutionProvider'])
face_app.prepare(ctx_id=0, det_size=(640, 640))

def compute_similarity(feat1, feat2):
    return np.dot(feat1, feat2) / (np.linalg.norm(feat1) * np.linalg.norm(feat2))

models.Base.metadata.create_all(bind=engine)

app = FastAPI(title="Liveness & Face Auth Backend")

def verify_api_key(api_key: str, db: Session) -> models.APIKey:
    db_key = db.query(models.APIKey).filter(models.APIKey.key == api_key).first()
    if not db_key or not db_key.is_active:
        raise HTTPException(status_code=401, detail="Invalid or inactive API Key")
    if db_key.expires_at and db_key.expires_at < datetime.datetime.utcnow():
        raise HTTPException(status_code=401, detail="API Key has expired")
    return db_key

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

@app.post("/compare_faces")
async def compare_faces(
    api_key: str = Form(...),
    cropped: bool = Form(True),
    reference_image: UploadFile = File(...),
    target_image: UploadFile = File(...),
    db: Session = Depends(get_db)
):
    # Verify the API key first
    verify_api_key(api_key, db)
    
    # Read buffers
    ref_bytes = await reference_image.read()
    tgt_bytes = await target_image.read()
    
    # Decode to BGR numpy arrays using OpenCV
    ref_img = cv2.imdecode(np.frombuffer(ref_bytes, np.uint8), cv2.IMREAD_COLOR)
    tgt_img = cv2.imdecode(np.frombuffer(tgt_bytes, np.uint8), cv2.IMREAD_COLOR)

    # Insightface inference
    ref_faces = face_app.get(ref_img)
    tgt_faces = face_app.get(tgt_img)

    if not ref_faces or not tgt_faces:
        return {
            "success": False,
            "message": "Face not detected in one or both images.",
            "similarity_score": 0.0,
            "threshold_met": False
        }
        
    # Get 512D embeddings
    ref_feat = ref_faces[0].embedding
    tgt_feat = tgt_faces[0].embedding
    
    # Cosine Similarity Calculation
    similarity = compute_similarity(ref_feat, tgt_feat)
    
    # Buffalo L similarity threshold is roughly 0.45 - 0.50 
    threshold = 0.45 
    is_match = bool(similarity >= threshold)
    
    return {
        "success": is_match,
        "similarity_score": float(similarity),
        "threshold_met": is_match,
        "message": "Verification successful" if is_match else "Faces do not match",
        "cropped_processed": cropped
    }

@app.post("/sync_logs")
def sync_logs(request: schemas.SyncLogsRequest, db: Session = Depends(get_db)):
    # Verify API key
    verify_api_key(request.api_key, db)
    
    inserted = 0
    for log_entry in request.logs:
        db_log = models.APILog(
            timestamp=log_entry.timestamp,
            user_id=str(log_entry.user_id) if log_entry.user_id else None,
            request_id=log_entry.request_id,
            device_id=log_entry.device_id,
            method=log_entry.method,
            parameters=json.dumps(log_entry.parameters) if log_entry.parameters else None,
            result=json.dumps(log_entry.result) if log_entry.result else None,
            errors=json.dumps(log_entry.errors) if log_entry.errors else None,
        )
        db.add(db_log)
        inserted += 1
        
    db.commit()
    return {"success": True, "logs_synced": inserted}
