from sqlalchemy import Boolean, Column, Integer, String, DateTime, Text, ForeignKey
import datetime
from database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True)
    email = Column(String, unique=True, index=True)

class APIKey(Base):
    __tablename__ = "api_keys"
    id = Column(Integer, primary_key=True, index=True)
    key = Column(String, unique=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"))
    is_active = Column(Boolean, default=True)
    expires_at = Column(DateTime)

class APILog(Base):
    __tablename__ = "api_logs"
    id = Column(Integer, primary_key=True, index=True)
    timestamp = Column(DateTime, default=datetime.datetime.utcnow)
    user_id = Column(String, index=True, nullable=True)
    request_id = Column(String, index=True)
    device_id = Column(String, index=True)
    method = Column(String)
    parameters = Column(Text, nullable=True)
    result = Column(Text, nullable=True)
    errors = Column(Text, nullable=True)
