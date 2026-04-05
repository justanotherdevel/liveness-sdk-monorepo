import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:flutter/foundation.dart';
import '../live_face_auth.dart';
import 'face_overlay_painter.dart';

// ── Lighting thresholds ────────────────────────────────────────────────────────
// These use a histogram-based approach that is more robust than mean-only,
// because the camera's auto-exposure (AE) shifts the mean toward mid-gray
// regardless of scene brightness.
//
// • Too dark : >40% of sampled Y pixels are below 60 (AE can't fix deep shadows)
// • Too bright: >15% of sampled Y pixels are at 245+ (blown highlights, AE can't recover)
const double _kDarkPixelThreshold = 60.0;   // Y below this = "dark pixel"
const double _kDarkFraction = 0.40;          // fraction of frame that must be dark
const double _kBrightPixelThreshold = 245.0; // Y above this = "saturated / blown"
const double _kBrightFraction = 0.15;        // fraction of frame that must be saturated

enum _LightingStatus { unknown, ok, tooDark, tooBright }

class AuthenticateFaceScreen extends StatefulWidget {
  final LiveFaceAuth sdk;

  const AuthenticateFaceScreen({super.key, required this.sdk});

  @override
  State<AuthenticateFaceScreen> createState() => _AuthenticateFaceScreenState();
}

class _AuthenticateFaceScreenState extends State<AuthenticateFaceScreen>
    with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(),
  );

  bool _isProcessing = false;
  bool _isAuthenticating = false;
  String _instructionText = 'Checking lighting…';
  Color _borderColor = Colors.grey;

  // ── Lighting gate ─────────────────────────────────────────────────────────
  // Starts as _LightingStatus.unknown.
  // Face detection only runs once this becomes .ok.
  // Any transition away from .ok immediately re-blocks face detection.
  _LightingStatus _lightingStatus = _LightingStatus.unknown;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
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
  }

  // ── Lighting check ─────────────────────────────────────────────────────────
  //
  // Uses a histogram-based method instead of mean-only:
  //   • Counts "dark" pixels (Y < 60) and "saturated" pixels (Y > 245).
  //   • If >40% dark  → tooDark
  //   • If >15% blown → tooBright
  //   • Otherwise     → ok
  //
  // Correctly reads Y values accounting for each row's bytesPerRow padding
  // (some SoCs pad rows to 32/64 byte boundaries — naive sequential reading
  // mixes padding bytes into the average, corrupting the result).
  _LightingStatus _computeLighting(CameraImage image) {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = plane.bytesPerRow;

    int darkCount = 0;
    int brightCount = 0;
    int total = 0;

    // Sample every 8th pixel in both dimensions for ~(w/8)*(h/8) samples.
    const int step = 8;

    if (Platform.isAndroid) {
      // NV21 / YUV_420_888: plane 0 is pure Y (one byte per pixel),
      // but each row is padded to rowStride bytes.
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
      // BGRA8888 (iOS): plane 0 is interleaved [B, G, R, A], 4 bytes per pixel.
      final int pixelStride = plane.bytesPerPixel ?? 4;
      for (int row = 0; row < height; row += step) {
        final int rowBase = row * rowStride;
        for (int col = 0; col < width; col += step) {
          final int idx = rowBase + col * pixelStride;
          if (idx + 2 >= bytes.length) break;
          final int b = bytes[idx] & 0xFF;
          final int g = bytes[idx + 1] & 0xFF;
          final int r = bytes[idx + 2] & 0xFF;
          // BT.601 luma
          final double y = 0.299 * r + 0.587 * g + 0.114 * b;
          if (y < _kDarkPixelThreshold) darkCount++;
          if (y > _kBrightPixelThreshold) brightCount++;
          total++;
        }
      }
    }

    if (total == 0) return _LightingStatus.ok;

    final double darkFrac = darkCount / total;
    final double brightFrac = brightCount / total;

    debugPrint(
      '[Lighting] dark=${(darkFrac * 100).toStringAsFixed(1)}% '
      'bright=${(brightFrac * 100).toStringAsFixed(1)}% '
      'samples=$total  ${image.width}x${image.height} stride=$rowStride',
    );

    if (darkFrac > _kDarkFraction) return _LightingStatus.tooDark;
    if (brightFrac > _kBrightFraction) return _LightingStatus.tooBright;
    return _LightingStatus.ok;
  }

  // ── Camera frame handler ───────────────────────────────────────────────────

  void _handleCameraImage(CameraImage image) async {
    if (_isProcessing || _isAuthenticating) return;
    _isProcessing = true;

    try {
      // ── Step 1: Lighting check — ALWAYS first, ALWAYS blocks on failure ──
      final _LightingStatus lighting = _computeLighting(image);

      if (lighting != _lightingStatus) {
        setState(() {
          _lightingStatus = lighting;
          // Reset instruction text whenever lighting goes bad
          if (lighting != _LightingStatus.ok) {
            _instructionText = 'Align your face within the frame';
            _borderColor = Colors.redAccent;
          }
        });
      }

      // Hard gate: lighting must be confirmed OK on THIS frame before
      // any image is passed to face detection or the auth engine.
      if (lighting != _LightingStatus.ok) return;

      // ── Step 2: Face detection ────────────────────────────────────────────
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final Size imageSize = Size(
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final camera = _cameraController!.description;
      final imageRotation =
          InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
          InputImageRotation.rotation270deg;
      final inputImageFormat =
          InputImageFormatValue.fromRawValue(image.format.raw) ??
          InputImageFormat.nv21;

      final inputData = InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      );

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: inputData,
      );
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        setState(() {
          _instructionText = 'Center your face in the frame';
          _borderColor = Colors.redAccent;
        });
      } else {
        final face = faces.first;
        final bounds = face.boundingBox;

        if (bounds.width < imageSize.width * 0.3) {
          setState(() {
            _instructionText = 'Move closer';
            _borderColor = Colors.orangeAccent;
          });
          return;
        }

        setState(() {
          _instructionText = 'Scanning… Please hold still.';
          _borderColor = Colors.blueAccent;
          _isAuthenticating = true;
        });

        await _cameraController!.stopImageStream();
        await _authenticateCapturedFace();
      }
    } catch (e) {
      debugPrint('Error processing frame: $e');
    } finally {
      if (mounted) _isProcessing = false;
    }
  }

  Future<void> _authenticateCapturedFace() async {
    try {
      final xFile = await _cameraController!.takePicture();
      final bytes = await xFile.readAsBytes();
      final base64String = base64Encode(bytes);

      final result = await widget.sdk.checkFaceAuth(
        targetImageBase64: base64String,
        useReference: true,
        passiveLiveness: true,
      );

      if (mounted) {
        if (result.success) {
          setState(() {
            _instructionText = 'Authentication Successful!';
            _borderColor = Colors.green;
          });
          await Future.delayed(const Duration(milliseconds: 700));
        } else {
          setState(() {
            _instructionText = 'Authentication Failed.';
            _borderColor = Colors.red;
          });
          await Future.delayed(const Duration(milliseconds: 1000));
        }
        if (!mounted) return;
        Navigator.pop(context, result);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _instructionText = 'System Error. Please try again.';
          _borderColor = Colors.red;
        });
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        Navigator.pop(context, FaceAuthResult(success: false, strong: false));
      }
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetector.close();
    _pulseController.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  String get _lightingInstructionText {
    switch (_lightingStatus) {
      case _LightingStatus.tooDark:
        return 'Move to a well-lit area or\nturn on a light facing you';
      case _LightingStatus.tooBright:
        return 'Avoid bright lights or\ndirect sunlight behind you';
      case _LightingStatus.unknown:
        return 'Checking lighting…';
      case _LightingStatus.ok:
        return _instructionText;
    }
  }

  Color get _effectiveBorderColor {
    if (_lightingStatus == _LightingStatus.tooDark) return const Color(0xFF6C63FF);
    if (_lightingStatus == _LightingStatus.tooBright) return const Color(0xFFFFC107);
    return _borderColor;
  }

  @override
  Widget build(BuildContext context) {
    final bool lightingBad = _lightingStatus == _LightingStatus.tooDark ||
        _lightingStatus == _LightingStatus.tooBright;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview
          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            CameraPreview(_cameraController!),

          // Face oval overlay
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

          // ── Lighting warning banner ──────────────────────────────────────
          if (lightingBad)
            Positioned(
              top: 110,
              left: 20,
              right: 20,
              child: _LightingWarningBanner(
                status: _lightingStatus,
                animation: _pulseAnimation,
              ),
            ),

          // ── Instruction card ─────────────────────────────────────────────
          Positioned(
            bottom: 100,
            left: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
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
                  if (_isAuthenticating)
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
                      _lightingInstructionText,
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

// ── Lighting warning widget ────────────────────────────────────────────────────

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
    final Color border = isDark
        ? const Color(0xFF6C63FF)
        : const Color(0xFFFFC107);
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
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, color: border, size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    hint,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.85),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
