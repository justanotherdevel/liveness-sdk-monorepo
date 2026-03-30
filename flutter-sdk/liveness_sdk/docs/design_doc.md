# SDK Architecture Design

## Core Philosophy
To provide a smooth, jitter-free user experience during continuous camera preview, the SDK architecture is aggressively decoupled into specialized "Engines." Each engine is strictly responsible for a single domain of the analysis pipeline. To prevent blocking the main UI thread, all heavy computations—including machine learning inference and image format conversions—are executed concurrently on separate background threads (Dart Isolates).

## Structural Breakdown: The 4 Engines

The SDK is composed of four specialized engines that handle distinct parts of the verification process:

### 1. Face Extraction Engine
**Responsibility**: Detects and extracts (crops) the face from the raw camera frame.
- **Rationale**: Both liveness detection and face matching require closely cropped face images rather than the entire camera frame. Extracting the face early in the pipeline limits the payload size passed to downstream ML models.
- **Capabilities**: Uses Google ML Kit Face Detection. It identifies the bounding box of the prominent face, enforces positional requirements (e.g., minimum padding, face centering), and executes the crop.

### 2. Passive Liveness Engine
**Responsibility**: Determines whether the presented face is real or a spoof (e.g., printed photo, screen replay) independently from a single static frame.
- **Rationale**: Passive liveness relies on a dedicated anti-spoofing neural network (`minifasnet.onnx`) requiring specialized preprocessing and tensor shaping.
- **Capabilities**: Consumes the cropped image from the Face Extraction Engine, feeds it to the model, and outputs a normalized liveness confidence score.

### 3. Active Liveness Engine
**Responsibility**: Evaluates challenge-response actions over a sequence of frames to ensure the user is physically present and actively participating.
- **Rationale**: Unlike the other engines, active liveness requires tracking state over time (temporal logic) to evaluate motion.
- **Capabilities**: Specifically detects and tracks:
  - **Blink**: Using eye-open probability thresholds.
  - **Head Nod**: Tracking pitch (up and down) vector changes.
  - **Head Shake**: Tracking yaw (left and right) vector changes.

### 4. Face Match Engine
**Responsibility**: Vectorizes face images and computes biometric similarity between two faces.
- **Rationale**: Distinct from liveness, this engine uses a separate embedded model (`arcface.onnx`) strictly meant to generate and compare feature embeddings.
- **Capabilities**:
  - **Vectorization**: Passes the cropped face through the ArcFace logic to generate a high-dimensional feature vector.
  - **Comparison**: Computes the cosine similarity or Euclidean distance between a generated vector and a stored reference vector.

## Concurrency and Threading Model

Since live camera feeds typically process 30 to 60 frames per second, running ML models or heavy image manipulations on the main Dart isolate will cause severe frame drops and UI jitter. 

### Isolate Strategy
- Each engine will operate its logic within Dart `Isolate`s (using worker pools, `Isolate.spawn`, or the `compute` wrapper).
- **Zero UI-Blocking**: The main thread's responsibilities will be strictly confined to:
  1. Managing the UI state.
  2. Rendering the camera preview.
  3. Routing frame data (pointers or bytes) to the background isolates via `SendPort`.

### Format Conversion Requirements
- **Camera Stream Formats**: Camera plugins stream raw buffers (e.g., YUV420 on Android, BGRA8888 on iOS).
- **Preprocessing Constraints**: ONNX and TFLite neural networks generally expect standardized, multi-dimensional array tensors mapped from RGB values.
- **Threaded Execution**: Converting YUV bytes to RGB pixels requires looping over millions of bytes per frame. This image format conversion logic **must** be executed entirely on the background threads before passing the data to the neural networks.
