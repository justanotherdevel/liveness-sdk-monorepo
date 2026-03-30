from fastapi import FastAPI, Depends, HTTPException, status, File, UploadFile, Form
from sqlalchemy.orm import Session
import models, schemas
from database import engine, get_db
import datetime
import json

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
def compare_faces(
    api_key: str = Form(...),
    cropped: bool = Form(True),
    reference_image: UploadFile = File(...),
    target_image: UploadFile = File(...),
    db: Session = Depends(get_db)
):
    # Verify the API key first
    verify_api_key(api_key, db)
    
    # MOCK FACE COMPARISON LOGIC
    # In production, this would use an actual ML model instance
    
    return {
        "success": True,
        "similarity_score": 95.5, # Mock similarity score
        "threshold_met": True,
        "message": "Fallback deep verification successful (MOCK)",
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
