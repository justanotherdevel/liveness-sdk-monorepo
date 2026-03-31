# Flutter SDK Documentation

## Overview
A private Flutter SDK for passive and active liveness detection, as well as Face Authentication. The SDK utilizes Google ML Kit for face detection and cropping, `minifasnet.onnx` for liveness scoring, and `arcface.onnx` for on-device face comparison. It is designed to operate primarily offline with server fallbacks.

## Initialization
```dart
final _liveFaceAuth = await LiveFaceAuth({
  "apiKey": "your_api_key",
})
```
- **Validation Flow**: Checks local secure storage to see if the key was previously validated and whether it expires within 24 hours. 
- **Offline First**: If the key is valid and not expiring soon, the SDK initializes immediately without a network call. Otherwise, it calls the `validate_key` server endpoint to update local records.

## Core APIs

### `checkPassiveLiveness`
- **Input**: `image` (Base64 string).
- **Process**: Uses Google ML Kit to crop the face, then runs `minifasnet.onnx` to generate a liveness score. 
- **Output**: Returns `true` if the score exceeds the safe threshold, `false` otherwise.

### `checkFaceAuth`
- **Input**: `referenceImage` (Base64), `useReference` (default `false`), `image` (Base64), `passiveLiveness` (default `true`), `threshold` (default `80`), `proceedIfLivenessFail` (default `false`).
- **Process**: 
  1. Crops faces from both images using ML Kit. Uses stored reference from secure storage if `useReference` is `true`.
  2. Runs `minifasnet.onnx` on the target image to ensure liveness (if enabled). If it fails liveness and `proceedIfLivenessFail` is `false`, it returns immediately. If `proceedIfLivenessFail` is `true`, it continues to face matching regardless.
  3. Runs `arcface.onnx` to compare the reference and target face.
  4. If the similarity score is above the `threshold`, records success.
  5. If the score is below the threshold, dispatches the images to the backend server (`/compare_faces`) for a more accurate comparison.
  6. If offline during step 5, it returns `success: false` with `strong: false` (indicating a low-confidence decision).
- **Output**: `FaceAuthResult` object containing:
  - `success` (bool): Overall authentication result.
  - `strong` (bool): Was internet processing available if fallback was required?
  - `passiveLivenessResult` (bool?): The result of passive liveness (null if bypassed).
  - `activeLivenessResult` (bool?): The result of active liveness (null if bypassed).

### `enrollFaceLiveScreen`
- **Input**: `active` (default `false`), `activeLivenessChecks` (e.g., blink, head nod, head shake), `saveReference` (default `false`).
- **Process**: 
  - Launches a guided camera UI for face enrollment.
  - Implements environmental/positional checks: distance (via eye distance overlay), face size, lighting (too dark/backlit), masks, and glasses. Provides UI feedback (red/green borders).
  - If `active` is `true`, requires the user to perform randomized actions (nod, blink, etc.).
  - Auto-captures the picture 3 seconds after successful checks/actions.
  - Extracts the face and generates an ArcFace vector.
  - Overwrites the secure storage reference if `saveReference` is `true`.
- **Output**: Cropped face image and generated vector.

### `enrollFaceImage`
- **Input**: `image` (Base64), `saveReference` (default `false`).
- **Process**: Crops the face from a static image, generates the ArcFace vector, and returns them both. Saves to secure storage if `saveReference` is `true`. Useful for ID cards or backend-provided reference images.

### `clearReference`
- **Process**: Deletes the saved reference image and vector from local secure storage.

### `isFaceEnrolled`
- **Output**: Returns a `bool` representing whether a reference face is currently enrolled/saved in local secure storage.

### `AuthenticateFaceScreen`
- **Input**: `passive` (default `true`), `active` (default `false`), `activeLivenessChecks`, `faceAuthThreshold` (default `80`).
- **Process**: 
  - Launches the guided UI flow (similar to `enrollFaceLiveScreen`).
  - Processes liveness and ArcFace comparison. 
  - Server Fallback: Sends the comparison to the server if the local score is under the threshold. Inherits the server's final result. If offline during fallback, returns `false` with `strong: false`.

## Telemetry and Logging
- All SDK interactions are logged to a local SQLite database in secure storage. 
- **Log Data**: Timestamp, `userId`, locally unique `requestId`, `deviceId`, method invoked, parameters, results, and local errors.
- **Sync**: Logs are encrypted and synced with the server autonomously whenever an internet connection is available, ensuring usage tracking and debugging without compromising privacy.
