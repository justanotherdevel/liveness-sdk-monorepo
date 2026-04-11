import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:flutter/foundation.dart';
import '../engines/active_liveness_engine.dart';
import '../live_face_auth.dart';
import 'face_overlay_painter.dart';

// ── Lighting thresholds ────────────────────────────────────────────────────────
const double _kDarkPixelThreshold = 60.0;
const double _kDarkFraction = 0.40;
const double _kBrightPixelThreshold = 245.0;
const double _kBrightFraction = 0.15;

// ── Internal enums ─────────────────────────────────────────────────────────────

enum _LightingStatus { unknown, ok, tooDark, tooBright }

/// The auth screen moves through these phases in order.
enum _AuthPhase {
  countdown,  // initial grace period — camera shows, nothing starts yet
  lighting,   // waiting for valid lighting
  faceAlign,  // lighting OK, waiting for face to be centred + close enough
  challenge,  // running active liveness challenges sequentially
  scanning,   // capturing frame + running auth pipeline
}

// ── Widget ─────────────────────────────────────────────────────────────────────

class AuthenticateFaceScreen extends StatefulWidget {
  final LiveFaceAuth sdk;

  /// Run passive liveness (anti-spoofing) before face matching.
  /// Defaults to true.
  final bool requirePassiveLiveness;

  /// Run active liveness challenges (blink / nod / head-shake) before
  /// capturing the auth frame. Defaults to false.
  final bool requireActiveLiveness;

  /// Which challenges to run when [requireActiveLiveness] is true.
  /// Defaults to {blink}. Order is deterministic (enum order).
  final Set<ActiveChallenge> activeChallenges;

  /// If true, a failed liveness check does NOT block authentication —
  /// face matching still proceeds. Useful for development / graceful degradation.
  /// Defaults to false.
  final bool proceedIfLivenessFails;

  /// Cosine-similarity threshold for face matching (0–1).
  /// A lower value is more permissive; higher is stricter.
  /// Defaults to 0.80. Applies to both on-device and server-fallback matching.
  final double threshold;

  const AuthenticateFaceScreen({
    super.key,
    required this.sdk,
    this.requirePassiveLiveness = true,
    this.requireActiveLiveness = false,
    this.activeChallenges = const {ActiveChallenge.blink},
    this.proceedIfLivenessFails = false,
    this.threshold = 0.80,
  });

  @override
  State<AuthenticateFaceScreen> createState() => _AuthenticateFaceScreenState();
}

class _AuthenticateFaceScreenState extends State<AuthenticateFaceScreen>
    with SingleTickerProviderStateMixin {
  // ── Camera ──────────────────────────────────────────────────────────────────
  CameraController? _cameraController;

  // ── ML Kit face detector ────────────────────────────────────────────────────
  // enableClassification → provides eye open probabilities (needed for blink).
  late final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true, // eye open probabilities for blink detection
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  // ── Active liveness ─────────────────────────────────────────────────────────
  final ActiveLivenessEngine _activeLivenessEngine = ActiveLivenessEngine();
  late final List<ActiveChallenge> _challengeQueue;
  int _currentChallengeIndex = 0;

  // ── Phase / UI state ────────────────────────────────────────────────────────
  _AuthPhase _phase = _AuthPhase.countdown;
  bool _isProcessing = false;
  bool _isAuthenticating = false;
  String _instructionText = 'Get ready…';
  Color _borderColor = Colors.grey;
  _LightingStatus _lightingStatus = _LightingStatus.unknown;

  // Countdown
  static const int _kCountdownSeconds = 5;
  int _countdown = _kCountdownSeconds;

  // Progress indicator for scanning phase
  bool _showProgress = false;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Lock to portrait for the duration of this screen.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Build challenge queue in stable enum order from the provided set.
    _challengeQueue = ActiveChallenge.values
        .where((c) => widget.activeChallenges.contains(c))
        .toList();

    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _cameraController = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    await _cameraController!.initialize();
    if (!mounted) return;
    _cameraController!.startImageStream(_handleCameraImage);
    setState(() {});
    _startCountdown();
  }

  void _startCountdown() {
    // Tick every second and decrement the counter.
    // During the countdown the camera stream is active for lighting checks
    // but face detection / auth are blocked.
    Future.delayed(const Duration(seconds: 1), _countdownTick);
  }

  void _countdownTick() {
    if (!mounted) return;
    setState(() {
      _countdown--;
      if (_countdown <= 0) {
        _phase = _AuthPhase.lighting; // hand off to normal flow
        _instructionText = 'Checking lighting…';
      }
    });
    if (_countdown > 0) {
      Future.delayed(const Duration(seconds: 1), _countdownTick);
    }
  }

  @override
  void dispose() {
    // Restore all orientations so the rest of the app is unaffected.
    SystemChrome.setPreferredOrientations([]);
    _cameraController?.dispose();
    _faceDetector.close();
    _pulseController.dispose();
    super.dispose();
  }

  // ── Lighting check ───────────────────────────────────────────────────────────

  _LightingStatus _computeLighting(CameraImage image) {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = plane.bytesPerRow;

    int darkCount = 0;
    int brightCount = 0;
    int total = 0;
    const int step = 8;

    if (Platform.isAndroid) {
      for (int row = 0; row < height; row += step) {
        final int rowBase = row * rowStride;
        for (int col = 0; col < width; col += step) {
          final int idx = rowBase + col;
          if (idx >= bytes.length) break;
          final int y = bytes[idx] & 0xFF;
          if (y < _kDarkPixelThreshold) darkCount++;
          if (y > _kBrightPixelThreshold) brightCount++;
          total++;
        }
      }
    } else {
      final int pixelStride = plane.bytesPerPixel ?? 4;
      for (int row = 0; row < height; row += step) {
        final int rowBase = row * rowStride;
        for (int col = 0; col < width; col += step) {
          final int idx = rowBase + col * pixelStride;
          if (idx + 2 >= bytes.length) break;
          final double y = 0.299 * (bytes[idx + 2] & 0xFF) +
              0.587 * (bytes[idx + 1] & 0xFF) +
              0.114 * (bytes[idx] & 0xFF);
          if (y < _kDarkPixelThreshold) darkCount++;
          if (y > _kBrightPixelThreshold) brightCount++;
          total++;
        }
      }
    }

    // If we couldn't sample any pixels (e.g. stride mismatch), stay unknown
    // rather than wrongly reporting OK and allowing a bad frame through.
    if (total == 0) return _LightingStatus.unknown;
    final double darkFrac = darkCount / total;
    final double brightFrac = brightCount / total;

    debugPrint(
      '[Lighting] dark=${(darkFrac * 100).toStringAsFixed(1)}%  '
      'bright=${(brightFrac * 100).toStringAsFixed(1)}%',
    );

    if (darkFrac > _kDarkFraction) return _LightingStatus.tooDark;
    if (brightFrac > _kBrightFraction) return _LightingStatus.tooBright;
    return _LightingStatus.ok;
  }

  // ── Challenge instruction helper ─────────────────────────────────────────────

  String _challengeInstruction(ActiveChallenge c) {
    switch (c) {
      case ActiveChallenge.blink:
        return 'Blink your eyes';
      case ActiveChallenge.headNod:
        return 'Nod your head up and down';
      case ActiveChallenge.headShake:
        return 'Shake your head left and right';
    }
  }

  // ── Main camera frame handler ─────────────────────────────────────────────

  void _handleCameraImage(CameraImage image) async {
    if (_isProcessing || _isAuthenticating) return;
    _isProcessing = true;

    try {
      // ── 1. Lighting check (every frame, cheap) ───────────────────────────
      final lighting = _computeLighting(image);
      if (lighting != _lightingStatus) {
        setState(() {
          _lightingStatus = lighting;
          // During countdown we still want to show lighting warnings, but we
          // must not change _phase away from countdown — the countdown ticks
          // independently and will transition to lighting on its own.
          if (lighting != _LightingStatus.ok && _phase != _AuthPhase.countdown) {
            _phase = _AuthPhase.lighting;
            _currentChallengeIndex = 0;
            _activeLivenessEngine.resetState();
            _instructionText = 'Align your face within the frame';
            _borderColor = Colors.redAccent;
          }
        });
      }

      // Gate 1: countdown still running — show lighting warnings but don't
      // start face detection or auth yet.
      if (_phase == _AuthPhase.countdown) return;

      // Gate 2: bad lighting stops all further processing this frame.
      if (_lightingStatus != _LightingStatus.ok) return;

      // ── 2. Advance from lighting → faceAlign once lighting is confirmed ──
      if (_phase == _AuthPhase.lighting) {
        setState(() {
          _phase = _AuthPhase.faceAlign;
          _instructionText = 'Align your face within the frame';
          _borderColor = Colors.redAccent;
        });
      }

      // ── 3. Face detection ────────────────────────────────────────────────
      final faces = await _runFaceDetection(image);

      if (faces.isEmpty) {
        if (_phase == _AuthPhase.faceAlign || _phase == _AuthPhase.challenge) {
          setState(() {
            _instructionText = 'Center your face in the frame';
            _borderColor = Colors.redAccent;
            // Reset challenge if user moved away
            if (_phase == _AuthPhase.challenge) {
              _currentChallengeIndex = 0;
              _activeLivenessEngine.resetState();
              _phase = _AuthPhase.faceAlign;
            }
          });
        }
        return;
      }

      final face = faces.first;
      final double imageWidth = image.width.toDouble();

      // Face size check
      if (face.boundingBox.width < imageWidth * 0.28) {
        setState(() {
          _instructionText = 'Move closer';
          _borderColor = Colors.orangeAccent;
        });
        return;
      }

      // ── 4. Active liveness phase ─────────────────────────────────────────
      if (_phase == _AuthPhase.faceAlign &&
          widget.requireActiveLiveness &&
          _challengeQueue.isNotEmpty) {
        // Face is good — start active challenges
        setState(() {
          _phase = _AuthPhase.challenge;
          _currentChallengeIndex = 0;
          _activeLivenessEngine.resetState();
          _instructionText =
              _challengeInstruction(_challengeQueue[0]);
          _borderColor = Colors.blueAccent;
        });
        return;
      }

      if (_phase == _AuthPhase.challenge) {
        final currentChallenge = _challengeQueue[_currentChallengeIndex];
        final completed = _activeLivenessEngine.verifyChallenge(
          face: face,
          challenge: currentChallenge,
        );

        if (completed) {
          _currentChallengeIndex++;
          if (_currentChallengeIndex >= _challengeQueue.length) {
            // All challenges done → proceed to capture
            _startCapture();
          } else {
            _activeLivenessEngine.resetState();
            setState(() {
              _instructionText = _challengeInstruction(
                _challengeQueue[_currentChallengeIndex],
              );
              _borderColor = Colors.blueAccent;
            });
          }
        } else {
          // Update instruction text to stay current
          final expected = _challengeInstruction(currentChallenge);
          if (_instructionText != expected) {
            setState(() {
              _instructionText = expected;
              _borderColor = Colors.blueAccent;
            });
          }
        }
        return;
      }

      // ── 5. faceAlign → capture (no active liveness, or all done) ────────
      if (_phase == _AuthPhase.faceAlign) {
        _startCapture();
      }
    } catch (e) {
      debugPrint('[AuthScreen] Frame error: $e');
    } finally {
      if (mounted) _isProcessing = false;
    }
  }

  void _startCapture() {
    if (_isAuthenticating) return;
    // Hard gate: if the stream-based lighting check says the current frame is
    // bad, do not capture. The next frame will re-evaluate.
    if (_lightingStatus != _LightingStatus.ok) return;
    setState(() {
      _isAuthenticating = true;
      _phase = _AuthPhase.scanning;
      _instructionText = 'Scanning… Please hold still.';
      _borderColor = Colors.blueAccent;
      _showProgress = true;
    });
    _cameraController!.stopImageStream().then((_) => _captureAndAuthenticate());
  }

  // ── Face detection helper ────────────────────────────────────────────────────

  Future<List<Face>> _runFaceDetection(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();
    final imageSize =
        Size(image.width.toDouble(), image.height.toDouble());
    final camera = _cameraController!.description;
    final imageRotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
            InputImageRotation.rotation270deg;
    final inputImageFormat =
        InputImageFormatValue.fromRawValue(image.format.raw) ??
            InputImageFormat.nv21;
    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
    return _faceDetector.processImage(inputImage);
  }

  // ── Auth pipeline ────────────────────────────────────────────────────────────

  Future<void> _captureAndAuthenticate() async {
    try {
      final xFile = await _cameraController!.takePicture();
      final bytes = await xFile.readAsBytes();

      // Verify lighting on the ACTUAL captured JPEG — not the last stream frame.
      // The camera's auto-exposure can shift between the stream check and
      // takePicture(), so we re-sample the image we're about to send to liveness.
      final capturedLightingOk = await _isJpegWellLit(bytes);
      if (!capturedLightingOk) {
        debugPrint('[AuthScreen] Captured frame has bad lighting — retrying.');
        if (mounted) {
          setState(() {
            _isAuthenticating = false;
            _showProgress = false;
            _phase = _AuthPhase.lighting;
            _instructionText = 'Adjust lighting and try again';
            _borderColor = Colors.redAccent;
          });
          await _cameraController!.startImageStream(_handleCameraImage);
        }
        return;
      }

      final base64String = base64Encode(bytes);

      final result = await widget.sdk.checkFaceAuth(
        targetImageBase64: base64String,
        useReference: true,
        passiveLiveness: widget.requirePassiveLiveness,
        proceedIfLivenessFail: widget.proceedIfLivenessFails,
        threshold: widget.threshold,
      );

      // Attach active liveness result
      final finalResult = FaceAuthResult(
        success: result.success,
        strong: result.strong,
        passiveLivenessResult: result.passiveLivenessResult,
        // active liveness passed if we made it past the challenge phase
        activeLivenessResult: widget.requireActiveLiveness ? true : null,
      );

      if (mounted) {
        if (finalResult.success) {
          setState(() {
            _instructionText = 'Authentication Successful!';
            _borderColor = Colors.green;
            _showProgress = false;
          });
          await Future.delayed(const Duration(milliseconds: 600));
        } else {
          setState(() {
            _instructionText = 'Authentication Failed.';
            _borderColor = Colors.red;
            _showProgress = false;
          });
          await Future.delayed(const Duration(milliseconds: 1000));
        }
        if (!mounted) return;
        Navigator.pop(context, finalResult);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _instructionText = 'System Error. Please try again.';
          _borderColor = Colors.red;
          _showProgress = false;
        });
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        Navigator.pop(context, FaceAuthResult(success: false, strong: false));
      }
    }
  }

  // ── JPEG lighting check ──────────────────────────────────────────────────────

  /// Decodes [jpegBytes] and samples luminance to decide if the captured image
  /// has acceptable lighting for liveness analysis.
  /// Returns true if lighting is OK, false if too dark or too bright.
  Future<bool> _isJpegWellLit(Uint8List jpegBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(jpegBytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final int w = img.width;
      final int h = img.height;
      final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (byteData == null || w == 0 || h == 0) return true;

      final pixels = byteData.buffer.asUint8List();
      int darkCount = 0, brightCount = 0, total = 0;
      const int step = 10; // sample ~1% of pixels — fast enough
      for (int row = 0; row < h; row += step) {
        for (int col = 0; col < w; col += step) {
          final int idx = (row * w + col) * 4; // RGBA
          if (idx + 2 >= pixels.length) break;
          final double lum =
              0.299 * pixels[idx] +      // R
              0.587 * pixels[idx + 1] +  // G
              0.114 * pixels[idx + 2];   // B
          if (lum < _kDarkPixelThreshold) darkCount++;
          if (lum > _kBrightPixelThreshold) brightCount++;
          total++;
        }
      }
      if (total == 0) return true;
      final double darkFrac = darkCount / total;
      final double brightFrac = brightCount / total;
      debugPrint(
        '[AuthScreen] Captured-JPEG lighting — '
        'dark=${(darkFrac * 100).toStringAsFixed(1)}%  '
        'bright=${(brightFrac * 100).toStringAsFixed(1)}%',
      );
      return darkFrac <= _kDarkFraction && brightFrac <= _kBrightFraction;
    } catch (e) {
      debugPrint('[AuthScreen] _isJpegWellLit error: $e');
      return true; // fail open — don't block auth on a decode error
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  bool get _inCountdown => _phase == _AuthPhase.countdown;

  bool get _lightingBad =>
      _lightingStatus == _LightingStatus.tooDark ||
      _lightingStatus == _LightingStatus.tooBright;

  Color get _effectiveBorderColor {
    if (_lightingStatus == _LightingStatus.tooDark) {
      return const Color(0xFF6C63FF);
    }
    if (_lightingStatus == _LightingStatus.tooBright) {
      return const Color(0xFFFFC107);
    }
    return _borderColor;
  }


  String get _displayInstruction {
    if (_inCountdown) {
      return _countdown > 0
          ? 'Starting in $_countdown…'
          : 'Get ready…';
    }
    if (_lightingBad) {
      return _lightingStatus == _LightingStatus.tooDark
          ? 'Move to a well-lit area or\nturn on a light facing you'
          : 'Avoid bright lights or\ndirect sunlight behind you';
    }
    return _instructionText;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            CameraPreview(_cameraController!),

          CustomPaint(
            painter: FaceOverlayPainter(borderColor: _effectiveBorderColor),
            child: Container(),
          ),

          // Title
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: const Center(
              child: Text(
                'Face Authentication',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
            ),
          ),

          // Countdown ring — only shown during countdown phase
          if (_inCountdown)
            Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  '$_countdown',
                  key: ValueKey(_countdown),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 96,
                    fontWeight: FontWeight.w900,
                    shadows: [
                      Shadow(
                        blurRadius: 30,
                        color: Colors.black87,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Active liveness progress indicator (challenge chips)
          if (widget.requireActiveLiveness &&
              _challengeQueue.isNotEmpty &&
              (_phase == _AuthPhase.challenge ||
                  _phase == _AuthPhase.faceAlign))
            Positioned(
              top: 100,
              left: 20,
              right: 20,
              child: _ChallengeProgressRow(
                challenges: _challengeQueue,
                completedCount: _currentChallengeIndex,
              ),
            ),

          // Lighting warning banner
          if (_lightingBad)
            Positioned(
              top: widget.requireActiveLiveness ? 160 : 110,
              left: 20,
              right: 20,
              child: _LightingWarningBanner(
                status: _lightingStatus,
                animation: _pulseAnimation,
              ),
            ),

          // Instruction card
          Positioned(
            bottom: 100,
            left: 24,
            right: 24,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 24,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_showProgress)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.blueAccent,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      _displayInstruction,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Close button
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: InkWell(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white30),
                  ),
                  child: const Icon(
                    Icons.close,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Active challenge progress row ─────────────────────────────────────────────

class _ChallengeProgressRow extends StatelessWidget {
  final List<ActiveChallenge> challenges;
  final int completedCount;

  const _ChallengeProgressRow({
    required this.challenges,
    required this.completedCount,
  });

  String _label(ActiveChallenge c) {
    switch (c) {
      case ActiveChallenge.blink:
        return 'Blink';
      case ActiveChallenge.headNod:
        return 'Nod';
      case ActiveChallenge.headShake:
        return 'Shake';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(challenges.length, (i) {
        final done = i < completedCount;
        final active = i == completedCount;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: done
                ? Colors.green.withValues(alpha: 0.9)
                : active
                    ? Colors.white.withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active ? Colors.blueAccent : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (done)
                const Icon(Icons.check, size: 14, color: Colors.white),
              if (done) const SizedBox(width: 4),
              Text(
                _label(challenges[i]),
                style: TextStyle(
                  color: done
                      ? Colors.white
                      : active
                          ? Colors.black87
                          : Colors.white70,
                  fontWeight:
                      active ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

// ── Lighting warning banner ───────────────────────────────────────────────────

class _LightingWarningBanner extends StatelessWidget {
  final _LightingStatus status;
  final Animation<double> animation;

  const _LightingWarningBanner({
    required this.status,
    required this.animation,
  });

  @override
  Widget build(BuildContext context) {
    final bool isDark = status == _LightingStatus.tooDark;
    final Color bg = isDark
        ? const Color(0xFF1A1A2E).withValues(alpha: 0.92)
        : const Color(0xFFFFF3CD).withValues(alpha: 0.95);
    final Color border =
        isDark ? const Color(0xFF6C63FF) : const Color(0xFFFFC107);
    final Color textColor =
        isDark ? Colors.white : const Color(0xFF5D4037);
    final IconData icon =
        isDark ? Icons.bedtime_outlined : Icons.wb_sunny_outlined;
    final String title = isDark ? 'Too Dark' : 'Too Bright';
    final String hint = isDark
        ? 'Move to a well-lit area or turn on a light facing you.'
        : 'Avoid bright lights or direct sunlight behind you.';

    return ScaleTransition(
      scale: animation,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: border.withValues(alpha: 0.3),
              blurRadius: 16,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, color: border, size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: textColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(hint,
                      style: TextStyle(
                          color: textColor.withValues(alpha: 0.85),
                          fontSize: 13,
                          height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
