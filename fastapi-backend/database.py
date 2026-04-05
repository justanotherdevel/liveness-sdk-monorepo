import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

# Build the PostgreSQL URL from individual env vars.
# Falls back to DATABASE_URL if set directly (useful for cloud deployments).
_DATABASE_URL = os.environ.get("DATABASE_URL") or (
    "postgresql://{user}:{password}@{host}:{port}/{db}".format(
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        host=os.environ.get("POSTGRES_HOST", "localhost"),
        port=os.environ.get("POSTGRES_PORT", "5432"),
        db=os.environ["POSTGRES_DB"],
    )
)

engine = create_engine(_DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
