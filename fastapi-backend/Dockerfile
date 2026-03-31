FROM python:3.10-slim

WORKDIR /app

# Install system dependencies required by opencv and insightface
RUN apt-get update && apt-get install -y \
    libgl1 \
    libglib2.0-0 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Ensure models directory exists for the user to mount/copy the model into
RUN mkdir -p /app/models

COPY . .

# Expose FastAPI default port
EXPOSE 8000

# Run the application
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
