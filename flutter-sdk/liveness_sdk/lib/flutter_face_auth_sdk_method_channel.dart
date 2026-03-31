import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_face_auth_sdk_platform_interface.dart';

/// An implementation of [FlutterFaceAuthSdkPlatform] that uses method channels.
class MethodChannelFlutterFaceAuthSdk extends FlutterFaceAuthSdkPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_face_auth_sdk');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
