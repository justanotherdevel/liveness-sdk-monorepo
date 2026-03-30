import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_face_auth_sdk/flutter_face_auth_sdk.dart';
import 'package:flutter_face_auth_sdk/flutter_face_auth_sdk_platform_interface.dart';
import 'package:flutter_face_auth_sdk/flutter_face_auth_sdk_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterFaceAuthSdkPlatform
    with MockPlatformInterfaceMixin
    implements FlutterFaceAuthSdkPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterFaceAuthSdkPlatform initialPlatform = FlutterFaceAuthSdkPlatform.instance;

  test('$MethodChannelFlutterFaceAuthSdk is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterFaceAuthSdk>());
  });

  test('getPlatformVersion', () async {
    FlutterFaceAuthSdk flutterFaceAuthSdkPlugin = FlutterFaceAuthSdk();
    MockFlutterFaceAuthSdkPlatform fakePlatform = MockFlutterFaceAuthSdkPlatform();
    FlutterFaceAuthSdkPlatform.instance = fakePlatform;

    expect(await flutterFaceAuthSdkPlugin.getPlatformVersion(), '42');
  });
}
