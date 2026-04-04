import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

enum ActiveChallenge { blink, headNod, headShake }

class ActiveLivenessEngine {
  // State variables for tracking continuous temporal gestures
  bool _blinkStarted = false;

  bool _nodUp = false;
  bool _nodDown = false;

  bool _shakeLeft = false;
  bool _shakeRight = false;

  // Experimental Thresholds (Can be adjusted based on field testing)
  static const double eyeClosedThreshold = 0.2;
  static const double eyeOpenThreshold = 0.85;

  static const double headPitchUpThreshold = 12.0;
  static const double headPitchDownThreshold = -12.0;

  static const double headYawLeftThreshold = -15.0;
  static const double headYawRightThreshold = 15.0;

  /// Resets the engine state.
  /// MUST be called whenever a new challenge begins or is switched.
  void resetState() {
    _blinkStarted = false;
    _nodUp = false;
    _nodDown = false;
    _shakeLeft = false;
    _shakeRight = false;
  }

  /// Processes a single face frame sequentially and returns true if the challenge is completed.
  /// This should be called repeatedly as camera frames arrive.
  ///
  /// The [Face] object should be passed from the continuous ML Kit FaceDetector stream.
  bool verifyChallenge({
    required Face face,
    required ActiveChallenge challenge,
  }) {
    switch (challenge) {
      case ActiveChallenge.blink:
        return _detectBlink(face);
      case ActiveChallenge.headNod:
        return _detectHeadNod(face);
      case ActiveChallenge.headShake:
        return _detectHeadShake(face);
    }
  }

  bool _detectBlink(Face face) {
    if (face.leftEyeOpenProbability == null ||
        face.rightEyeOpenProbability == null) {
      return false; // ML Kit didn't detect eyes clearly in this frame
    }

    final double leftEye = face.leftEyeOpenProbability!;
    final double rightEye = face.rightEyeOpenProbability!;

    // Registration of the start of a blink (eyes closed)
    if (leftEye < eyeClosedThreshold && rightEye < eyeClosedThreshold) {
      _blinkStarted = true;
    }
    // Registration of the end of a blink (eyes open AFTER having been closed)
    else if (_blinkStarted &&
        leftEye > eyeOpenThreshold &&
        rightEye > eyeOpenThreshold) {
      _blinkStarted = false;
      return true; // Challenge completed
    }

    return false;
  }

  bool _detectHeadNod(Face face) {
    // headEulerAngleX represents pitch (looking up is positive, down is negative).
    final double pitch = face.headEulerAngleX ?? 0.0;

    if (pitch > headPitchUpThreshold) {
      _nodUp = true;
    } else if (pitch < headPitchDownThreshold) {
      _nodDown = true;
    }

    // Nod completed if both up and down were sequentially detected and head returns near center
    // We use a small threshold (e.g., < 5.0 degrees) to define "center"
    if (_nodUp && _nodDown && pitch.abs() < 5.0) {
      _nodUp = false;
      _nodDown = false;
      return true;
    }

    return false;
  }

  bool _detectHeadShake(Face face) {
    // headEulerAngleY represents yaw (looking right is positive, left is negative).
    final double yaw = face.headEulerAngleY ?? 0.0;

    if (yaw < headYawLeftThreshold) {
      _shakeLeft = true;
    } else if (yaw > headYawRightThreshold) {
      _shakeRight = true;
    }

    // Shake completed if both left and right were sequentially detected and head returns near center
    if (_shakeLeft && _shakeRight && yaw.abs() < 5.0) {
      _shakeLeft = false;
      _shakeRight = false;
      return true;
    }

    return false;
  }
}
