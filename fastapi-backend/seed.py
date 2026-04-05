#!/usr/bin/env python3
"""
Seed script — run once after the stack is up to insert an initial API key.

Usage (from the fastapi-backend/ directory):
    podman compose exec api python seed.py
    # or with a custom key:
    API_KEY=my-secret-key podman compose exec api python seed.py
"""
import os
import sys
from database import SessionLocal, engine
import models

# Ensure tables exist (idempotent)
models.Base.metadata.create_all(bind=engine)

db = SessionLocal()

api_key_value = os.environ.get("API_KEY", "test-api-key-123")

existing = db.query(models.APIKey).filter(models.APIKey.key == api_key_value).first()
if existing:
    print(f"Key '{api_key_value}' already exists (active={existing.is_active}). Nothing inserted.")
    sys.exit(0)

key = models.APIKey(key=api_key_value, is_active=True)
db.add(key)
db.commit()
db.refresh(key)
print(f"Inserted API key: '{api_key_value}' (id={key.id})")
db.close()
