import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_face_auth_sdk/liveness_sdk.dart';

class HomeScreen extends StatefulWidget {
  final LiveFaceAuth sdk;

  const HomeScreen({super.key, required this.sdk});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isEnrolled = false;

  // Dialog State
  bool _requirePassiveLiveness = true;
  bool _requireActiveLiveness = false;
  bool _activeBlink = true;
  bool _activeNod = true;
  bool _activeShake = false;
  bool _proceedIfLivenessFail = false;

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _checkEnrollment();
  }

  Future<void> _checkEnrollment() async {
    final enrolled = await widget.sdk.isFaceEnrolled();
    setState(() {
      _isEnrolled = enrolled;
    });
  }

  void _showResultDialog(String title, String message, {bool success = true}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              success ? Icons.check_circle : Icons.error,
              color: success ? Colors.green : Colors.red,
            ),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  Future<void> _handleStaticImageEnrollment() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    final bytes = await image.readAsBytes();
    final base64Image = base64Encode(bytes);

    final result = await widget.sdk.enrollFaceImage(
      imageBase64: base64Image,
      saveReference: true,
    );
    if (result.croppedFace != null) {
      _checkEnrollment();
      _showResultDialog(
        "Enrollment Successful",
        "Face from static image securely stored.",
      );
    } else {
      _showResultDialog(
        "Enrollment Failed",
        "Could not detect a clear face in the provided image.",
        success: false,
      );
    }
  }

  void _showEnrollmentOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                "Enrollment Options",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.blue),
              title: const Text("Live Camera Enrollment"),
              onTap: () async {
                Navigator.pop(context);
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EnrollFaceScreen(
                      sdk: widget.sdk,
                      requireActiveLiveness: true,
                    ),
                  ),
                );
                if (result != null &&
                    result is EnrollResult &&
                    result.croppedFace != null) {
                  _checkEnrollment();
                  _showResultDialog(
                    "Enrollment Successful",
                    "Live face successfully securely enrolled.",
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.image, color: Colors.blue),
              title: const Text("Static Image Enrollment"),
              onTap: () {
                Navigator.pop(context);
                _handleStaticImageEnrollment();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAuthenticationSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setStateModal) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
              left: 16,
              right: 16,
              top: 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Authentication Configuration",
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),

                  SwitchListTile(
                    title: const Text("Require Passive Liveness"),
                    value: _requirePassiveLiveness,
                    onChanged: (val) =>
                        setStateModal(() => _requirePassiveLiveness = val),
                  ),

                  SwitchListTile(
                    title: const Text("Require Active Liveness"),
                    value: _requireActiveLiveness,
                    onChanged: (val) =>
                        setStateModal(() => _requireActiveLiveness = val),
                  ),

                  if (_requireActiveLiveness)
                    Padding(
                      padding: const EdgeInsets.only(left: 32.0),
                      child: Column(
                        children: [
                          CheckboxListTile(
                            title: const Text("Blink"),
                            value: _activeBlink,
                            onChanged: (val) => setStateModal(
                              () => _activeBlink = val ?? false,
                            ),
                          ),
                          CheckboxListTile(
                            title: const Text("Nod"),
                            value: _activeNod,
                            onChanged: (val) =>
                                setStateModal(() => _activeNod = val ?? false),
                          ),
                          CheckboxListTile(
                            title: const Text("Shake"),
                            value: _activeShake,
                            onChanged: (val) => setStateModal(
                              () => _activeShake = val ?? false,
                            ),
                          ),
                        ],
                      ),
                    ),

                  SwitchListTile(
                    title: const Text("Proceed if Liveness Fails"),
                    subtitle: const Text(
                      "Proceeds to face auth even if spoof detected",
                    ),
                    value: _proceedIfLivenessFail,
                    onChanged: (val) =>
                        setStateModal(() => _proceedIfLivenessFail = val),
                  ),

                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        _launchAuthenticate();
                      },
                      child: const Text(
                        "Start Authentication",
                        style: TextStyle(fontSize: 18, color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _launchAuthenticate() async {
    // The AuthenticateFaceScreen currently implicitly takes required liveness rules
    // based on its default design. We can augment the AuthenticateFaceScreen in a real deployment
    // to ingest the ActiveLiveness rules directly. For now, it performs checking.
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AuthenticateFaceScreen(sdk: widget.sdk),
      ),
    );

    if (result != null && result is FaceAuthResult) {
      String log =
          "Auth Match Successful: ${result.success}\nStrong Model Processed: ${result.strong}";

      if (result.passiveLivenessResult != null) {
        log += "\nPassive Liveness Passed: ${result.passiveLivenessResult}";
      }

      if (result.activeLivenessResult != null) {
        log += "\nActive Liveness Passed: ${result.activeLivenessResult}";
      }

      _showResultDialog(
        result.success ? "Authentication Passed" : "Authentication Failed",
        log,
        success: result.success,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Biometric SDK Testbed",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 20),

            // Status Card
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade200),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Icon(
                    _isEnrolled ? Icons.check_circle : Icons.person_off,
                    size: 80,
                    color: _isEnrolled ? Colors.green : Colors.grey.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _isEnrolled ? "Status: Enrolled" : "Status: Not Enrolled",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: _isEnrolled
                          ? Colors.green.shade700
                          : Colors.black54,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 48),

            if (!_isEnrolled)
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.blue.shade700,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _showEnrollmentOptions,
                child: const Text(
                  "Enroll Face",
                  style: TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),

            if (_isEnrolled) ...[
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.blue.shade700,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _showAuthenticationSettings,
                child: const Text(
                  "Authenticate Face",
                  style: TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: const BorderSide(color: Colors.redAccent),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () async {
                  await widget.sdk.clearReference();
                  _checkEnrollment();
                },
                child: const Text(
                  "Unenroll",
                  style: TextStyle(fontSize: 18, color: Colors.redAccent),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
