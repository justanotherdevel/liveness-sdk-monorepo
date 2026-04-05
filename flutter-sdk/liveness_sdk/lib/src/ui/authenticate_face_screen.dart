import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:flutter/foundation.dart';
import '../live_face_auth.dart';
import 'face_overlay_painter.dart';

class AuthenticateFaceScreen extends StatefulWidget {
  final LiveFaceAuth sdk;

  // Uses locally saved reference implicitly
  const AuthenticateFaceScreen({super.key, required this.sdk});

  @override
  State<AuthenticateFaceScreen> createState() => _AuthenticateFaceScreenState();
}

class _AuthenticateFaceScreenState extends State<AuthenticateFaceScreen> {
  CameraController? _cameraController;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(),
  );

  bool _isProcessing = false;
  bool _isAuthenticating = false;
  String _instructionText = "Align your face within the frame";
  Color _borderColor = Colors.redAccent;

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

  void _handleCameraImage(CameraImage image) async {
    if (_isProcessing || _isAuthenticating) return;
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
          _instructionText = "Center your face in the frame";
          _borderColor = Colors.redAccent;
        });
      } else {
        // Face found, checking alignment bounds
        final face = faces.first;
        final bounds = face.boundingBox;

        // Simple heuristic: face should be reasonably large in frame
        if (bounds.width < imageSize.width * 0.3) {
          setState(() {
            _instructionText = "Move closer";
            _borderColor = Colors.orangeAccent;
          });
          return;
        }

        setState(() {
          _instructionText = "Scanning... Please hold still.";
          _borderColor = Colors.blueAccent;
          _isAuthenticating = true;
        });

        await _cameraController!.stopImageStream();
        await _authenticateCapturedFace();
      }
    } catch (e) {
      debugPrint("Error processing frame: $e");
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
            _instructionText = "Authentication Successful!";
            _borderColor = Colors.green;
          });
          await Future.delayed(const Duration(milliseconds: 700));
        } else {
          setState(() {
            _instructionText = "Authentication Failed.";
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
          _instructionText = "System Error. Please try again.";
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            CameraPreview(_cameraController!),

          CustomPaint(
            painter: FaceOverlayPainter(borderColor: _borderColor),
            child: Container(),
          ),

          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                "Face Authentication",
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),

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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isAuthenticating)
                    const Padding(
                      padding: EdgeInsets.only(right: 12.0),
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
                      _instructionText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

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
