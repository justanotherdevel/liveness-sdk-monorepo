# Server APIs Documentation

## Overview
The backend server is a FastAPI application that supports the Liveness and Face Auth SDK. It handles API key validation and provides a high-accuracy, server-side face comparison fallback for conditions where local on-device processing yields low confidence.

## Endpoints

### 1. `POST /validate_key`
**Purpose**: Validates the provided API key during SDK initialization.
- **Input**: API Key.
- **Processing**: Checks the backend database to verify if the key is valid and currently active for the associated user.
- **Output**: Returns the validity status and the expiry date of the key.
*Note*: A more robust key management system handling key generation, revocation, and rotation may be implemented in the future.

### 2. `POST /compare_faces`
**Purpose**: Compares two face images using a more accurate (but slower) server-side model. This serves as a fallback when the local SDK model (`arcface.onnx`) returns a similarity score below the accepted threshold.
- **Input**: Two face images (reference and target), the API key, and an optional `cropped` boolean flag (defaults to `true`).
- **Processing**:
  - Validates the API key before processing. If invalid, returns an error.
  - If `cropped` is `true`, it runs the comparison directly on the provided images.
  - If `cropped` is `false`, it pre-processes the images to extract/crop the faces before running the comparison.
- **Output**: Returns the face similarity result.
- **Security & Reliability**: 
  - Logs all requests and results for monitoring and debugging.
  - Enforces rate limiting to prevent abuse and ensure fair usage.
  - Includes mechanisms to blacklist abused or compromised API keys.
  - Capable of notifying users when an API key is expiring or compromised.

### 3. Log Syncing Endpoint (e.g., `POST /sync_logs`)
**Purpose**: Receives encrypted SDK usage logs for diagnostics and analytics.
- **Input**: Encrypted logs containing `timestamp`, `userId`, `requestId`, `deviceId`, `method`, `parameters`, `result`, and `errors`.
- **Processing**: Stores the telemetry in a database. Used to monitor SDK performance, identify bugs/bottlenecks, and securely track API key usage.
