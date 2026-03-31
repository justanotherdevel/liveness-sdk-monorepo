import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class FaceOverlayPainter extends CustomPainter {
  final Color borderColor;

  FaceOverlayPainter({required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    // Fill the screen
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Aadhaar-style clean, bright white background mask
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final path = Path()..addRect(rect);

    // Central oval defining the face guide framing
    final ovalWidth = size.width * 0.75;
    final ovalHeight = size.height * 0.45;
    final ovalRect = Rect.fromCenter(
      center: Offset(
        size.width / 2,
        size.height * 0.4,
      ), // Slightly above center
      width: ovalWidth,
      height: ovalHeight,
    );

    final ovalPath = Path()..addOval(ovalRect);

    // Cut out the oval from the white background
    final combinedPath = Path.combine(PathOperation.difference, path, ovalPath);
    canvas.drawPath(combinedPath, paint);

    // Draw the bright clinical border bounding the hole
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0;

    canvas.drawOval(ovalRect, borderPaint);

    // Draw soft inner shadow to provide depth separating the device and the camera feed
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 8.0);

    canvas.drawOval(ovalRect, shadowPaint);
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) =>
      borderColor != oldDelegate.borderColor;
}
