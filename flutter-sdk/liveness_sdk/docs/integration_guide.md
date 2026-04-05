# Flutter Liveness SDK — Integration Guide

**Version:** v0.3.0  
**Repository:** `https://github.com/justanotherdevel/liveness-auth-repo` (private — ensure you have been granted access)

---

## Overview

The SDK provides on-device face enrolment and authentication with optional passive and active liveness detection. Models are downloaded automatically from the backend on first launch and cached on-device.

---

## 1. Prerequisites

- Flutter **3.10+**
- Android **minSdkVersion 21** or higher
- GitHub access to the private SDK repo (contact the project owner if you haven't been added)
- An **API key** issued by the project owner

---

## 2. Add the dependency

In your app's `pubspec.yaml`:

```yaml
dependencies:
  flutter_face_auth_sdk:
    git:
      url: https://github.com/justanotherdevel/liveness-auth-repo.git
      ref: v0.3.0
```

Run:

```bash
flutter pub get
```

---

## 3. Android setup

### `android/app/src/main/AndroidManifest.xml`

Add inside `<manifest>`:

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.INTERNET"/>
```

### `android/app/build.gradle`

```gradle
defaultConfig {
    minSdkVersion 21
    // ...
}
```

---

## 4. Initialise the SDK

Call once at app startup (e.g. in `main()` before `runApp`).

```dart
import 'package:flutter_face_auth_sdk/liveness_sdk.dart';

final sdk = await LiveFaceAuth.initialize(
  apiKey: 'YOUR_API_KEY',
);
```

> **Note:** On first launch, models (~20 MB) are downloaded from the backend and cached. Subsequent launches use the local cache unless a newer version is available on the server.

---

## 5. Enrol a face

Enrolment stores a facial embedding in **secure on-device storage**. You can enrol from a static image (gallery, asset, network) — no live camera required.

```dart
import 'dart:convert';
import 'package:image_picker/image_picker.dart';

// From gallery
final XFile? image = await ImagePicker().pickImage(source: ImageSource.gallery);
if (image == null) return;

final bytes = await image.readAsBytes();

final result = await sdk.enrollFaceImage(
  imageBase64: base64Encode(bytes),
  saveReference: true,   // persists to secure storage
);

if (result.croppedFace != null) {
  print('Enrolled successfully');
} else {
  print('No face detected in the image');
}
```

**Utility methods:**

```dart
// Check if a face is already enrolled
final bool enrolled = await sdk.isFaceEnrolled();

// Remove the stored embedding
await sdk.clearReference();
```

---

## 6. Authenticate with the live camera screen

Push `AuthenticateFaceScreen` and await the `FaceAuthResult`. The screen handles camera permissions, lighting validation, optional liveness challenges, and face matching internally.

```dart
import 'package:flutter_face_auth_sdk/liveness_sdk.dart';

final result = await Navigator.push<FaceAuthResult>(
  context,
  MaterialPageRoute(
    builder: (_) => AuthenticateFaceScreen(
      sdk: sdk,

      // ── Liveness options ──────────────────────────────────────────
      requirePassiveLiveness: true,   // anti-spoof model (recommended)
      requireActiveLiveness: false,   // challenge-response (blink / nod / shake)
      activeChallenges: {             // only relevant when requireActiveLiveness: true
        ActiveChallenge.blink,
        ActiveChallenge.headNod,
      },

      // ── Fallback behaviour ────────────────────────────────────────
      proceedIfLivenessFails: false,  // set true only for testing
    ),
  ),
);

if (result == null) {
  // User closed the screen manually
  return;
}

if (result.success) {
  print('Authenticated ✓');
} else {
  print('Authentication failed');
}
```

### `AuthenticateFaceScreen` parameter reference

| Parameter | Type | Default | Description |
|---|---|---|---|
| `sdk` | `LiveFaceAuth` | required | Initialised SDK instance |
| `requirePassiveLiveness` | `bool` | `true` | Runs on-device anti-spoof model before matching |
| `requireActiveLiveness` | `bool` | `false` | Prompts user to complete gesture challenges |
| `activeChallenges` | `Set<ActiveChallenge>` | `{blink}` | Which challenges to run (order: blink → nod → shake) |
| `proceedIfLivenessFails` | `bool` | `false` | If `true`, face matching runs even when liveness fails |

### `ActiveChallenge` values

| Value | Instruction shown |
|---|---|
| `ActiveChallenge.blink` | Blink your eyes |
| `ActiveChallenge.headNod` | Nod your head up and down |
| `ActiveChallenge.headShake` | Shake your head left and right |

---

## 7. `FaceAuthResult` fields

| Field | Type | Description |
|---|---|---|
| `success` | `bool` | `true` if overall authentication passed |
| `strong` | `bool` | `true` if decided on-device; `false` if server fallback was used |
| `passiveLivenessResult` | `bool?` | `true` = live person, `false` = spoof, `null` = not checked |
| `activeLivenessResult` | `bool?` | `true` if all challenges completed, `null` = not used |

---

## 8. Typical flows

### Minimal (face match only, no liveness)

```dart
AuthenticateFaceScreen(
  sdk: sdk,
  requirePassiveLiveness: false,
  proceedIfLivenessFails: false,
)
```

### Standard (passive liveness + face match)

```dart
AuthenticateFaceScreen(
  sdk: sdk,
  requirePassiveLiveness: true,       // default — can omit
  proceedIfLivenessFails: false,      // default — can omit
)
```

### High-assurance (passive + active liveness + face match)

```dart
AuthenticateFaceScreen(
  sdk: sdk,
  requirePassiveLiveness: true,
  requireActiveLiveness: true,
  activeChallenges: {
    ActiveChallenge.blink,
    ActiveChallenge.headNod,
    ActiveChallenge.headShake,
  },
  proceedIfLivenessFails: false,
)
```

---

## 9. Headless API (no camera UI)

If you want to run the auth pipeline on an image you already have (e.g. from your own camera implementation):

```dart
final result = await sdk.checkFaceAuth(
  targetImageBase64: base64EncodedJpeg,
  useReference: true,          // compare against enrolled face
  passiveLiveness: true,
  proceedIfLivenessFail: false,
  threshold: 0.80,             // cosine similarity threshold (0–1)
);
```

---

## 10. Important notes

> **Enrolment persistence**  
> The face embedding is stored in Flutter Secure Storage and survives app restarts. Always call `sdk.isFaceEnrolled()` before showing the authentication screen.

> **`proceedIfLivenessFails: true`**  
> Only use this during development or in flows where liveness is informational. In production this parameter should be `false` (the default).

> **Lighting detection**  
> The auth screen automatically checks environmental lighting on every camera frame. If conditions are too dark or too bright, face detection pauses and a banner prompts the user to adjust. This is built-in and requires no integration work.

> **First-launch model download**  
> The SDK blocks `initialize()` until models are verified. Show a loading indicator on your splash screen while awaiting the future.
