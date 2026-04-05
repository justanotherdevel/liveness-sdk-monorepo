# ── Stage 1: builder ──────────────────────────────────────────────────────────
# All compilation (gcc, pg headers, etc.) happens here.
# This stage is discarded after build — its tools never reach the final image.
FROM python:3.10-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /wheels

COPY requirements.txt .

# Build + collect all wheels into /wheels so the runtime stage can install them
# without needing a compiler.
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt


# ── Stage 2: runtime ──────────────────────────────────────────────────────────
# Clean slim image — only what the running process needs.
FROM python:3.10-slim AS runtime

# Runtime-only system libs:
#   libgl1        — OpenCV (even headless) needs libGL for some codecs
#   libglib2.0-0  — GLib (used by OpenCV internally)
#   libpq5        — PostgreSQL client library (psycopg2 links against this)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 \
    libglib2.0-0 \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Copy pre-built wheels from builder and install — no compiler needed.
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels /wheels/*.whl \
    && rm -rf /wheels

WORKDIR /app

# Copy only application source — models and other large runtime assets
# are injected via volume mounts in docker-compose.yml.
COPY . .

# Models directory placeholder (actual weights are volume-mounted at runtime).
RUN mkdir -p /app/models

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
