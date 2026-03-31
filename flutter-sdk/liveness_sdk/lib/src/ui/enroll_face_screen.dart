import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:flutter/foundation.dart';
import '../live_face_auth.dart';
import '../engines/active_liveness_engine.dart';
import 'face_overlay_painter.dart';

class EnrollFaceScreen extends StatefulWidget {
  final LiveFaceAuth sdk;
  final bool requireActiveLiveness;

  const EnrollFaceScreen({
    Key? key,
    required this.sdk,
    this.requireActiveLiveness = true,
  }) : super(key: key);

  @override
  State<EnrollFaceScreen> createState() => _EnrollFaceScreenState();
}

class _EnrollFaceScreenState extends State<EnrollFaceScreen> {
  CameraController? _CameraController;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      enableTracking: true,
    ),
  );
  final ActiveLivenessEngine _activeEngine = ActiveLivenessEngine();

  bool _isProcessing = false;
  String _instructionText = "Center your face in the oval";
  Color _borderColor = Colors.grey;

  int _challengeIndex = 0;
  final List<ActiveChallenge> _challenges = [
    ActiveChallenge.blink,
    ActiveChallenge.headNod,
  ];

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _CameraController = CameraController(
      front,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    await _CameraController!.initialize();
    if (!mounted) return;

    _CameraController!.startImageStream(_handleCameraImage);
    setState(() {});
  }

  void _handleCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final Size imageSize = Size(
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final camera = _CameraController!.description;
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
          _instructionText = "No face detected. Please step into the frame.";
          _borderColor = Colors.redAccent;
        });
      } else {
        final face = faces.first;

        if (!widget.requireActiveLiveness) {
          setState(() {
            _instructionText = "Hold still...";
            _borderColor = Colors.green;
          });
          await _captureAndEnroll();
          return;
        }

        // Active Liveness Routing
        final currentChallenge = _challenges[_challengeIndex];

        switch (currentChallenge) {
          case ActiveChallenge.blink:
            if (_instructionText != "Please blink your eyes") {
              setState(() => _instructionText = "Please blink your eyes");
            }
            break;
          case ActiveChallenge.headNod:
            if (_instructionText != "Please nod your head slowly") {
              setState(() => _instructionText = "Please nod your head slowly");
            }
            break;
          case ActiveChallenge.headShake:
            if (_instructionText != "Please shake your head left and right") {
              setState(
                () =>
                    _instructionText = "Please shake your head left and right",
              );
            }
            break;
        }

        setState(() => _borderColor = Colors.orangeAccent);

        final passed = _activeEngine.verifyChallenge(
          face: face,
          challenge: currentChallenge,
        );

        if (passed) {
          if (_challengeIndex < _challenges.length - 1) {
            _challengeIndex++;
            _activeEngine.resetState();
          } else {
            setState(() {
              _instructionText = "Verification Complete. Processing...";
              _borderColor = Colors.green;
            });
            await _CameraController!.stopImageStream();
            await _captureAndEnroll();
          }
        }
      }
    } catch (e) {
      debugPrint("Error processing frame: \$e");
    } finally {
      if (mounted) _isProcessing = false;
    }
  }

  Future<void> _captureAndEnroll() async {
    try {
      final xFile = await _CameraController!.takePicture();
      final bytes = await xFile.readAsBytes();
      final base64String = base64Encode(bytes);

      final result = await widget.sdk.enrollFaceImage(
        imageBase64: base64String,
        saveReference: true,
      );

      if (mounted) {
        Navigator.pop(context, result);
      }
    } catch (e) {
      setState(() {
        _instructionText = "Failed to capture. Please try again.";
        _borderColor = Colors.red;
      });
    }
  }

  @override
  void dispose() {
    _CameraController?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_CameraController != null &&
              _CameraController!.value.isInitialized)
            CameraPreview(_CameraController!),

          // Aadhaar clean white overlay
          CustomPaint(
            painter: FaceOverlayPainter(borderColor: _borderColor),
            child: Container(),
          ),

          // Header
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                "Face Enrollment",
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),

          // Instruction Card
          Positioned(
            bottom: 100,
            left: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Text(
                _instructionText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
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
                    color: Colors.grey.shade100,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    color: Colors.black54,
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
