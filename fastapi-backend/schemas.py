from pydantic import BaseModel
from typing import Optional, List, Any
from datetime import datetime

class ValidateKeyRequest(BaseModel):
    api_key: str

class ValidateKeyResponse(BaseModel):
    is_valid: bool
    expires_at: Optional[datetime] = None
    message: Optional[str] = None

class SyncLogEntry(BaseModel):
    timestamp: datetime
    user_id: Optional[str] = None
    request_id: str
    device_id: str
    method: str
    parameters: Optional[Any] = None
    result: Optional[Any] = None
    errors: Optional[Any] = None

class SyncLogsRequest(BaseModel):
    api_key: str
    logs: List[SyncLogEntry]
