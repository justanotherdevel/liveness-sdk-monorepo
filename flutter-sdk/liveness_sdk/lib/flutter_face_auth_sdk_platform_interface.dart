import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_face_auth_sdk_method_channel.dart';

abstract class FlutterFaceAuthSdkPlatform extends PlatformInterface {
  /// Constructs a FlutterFaceAuthSdkPlatform.
  FlutterFaceAuthSdkPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterFaceAuthSdkPlatform _instance = MethodChannelFlutterFaceAuthSdk();

  /// The default instance of [FlutterFaceAuthSdkPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterFaceAuthSdk].
  static FlutterFaceAuthSdkPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterFaceAuthSdkPlatform] when
  /// they register themselves.
  static set instance(FlutterFaceAuthSdkPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
