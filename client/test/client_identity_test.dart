import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggy_pal/services/client_identity.dart';
import 'package:piggy_pal/services/device_info.dart';

const _deviceChannel = MethodChannel('piggy_pal/device');

/// 模拟 Android 原生通道返回的设备信息。
void mockAndroidDevice({
  String androidId = '1a2b3c4d5e6f7a8b',
  String manufacturer = 'vivo',
  String model = 'V2025A',
  String osVersion = '15',
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_deviceChannel, (call) async {
        if (call.method != 'deviceInfo') return null;
        return {
          'android_id': androidId,
          'manufacturer': manufacturer,
          'model': model,
          'os_version': osVersion,
          'sdk_int': 35,
        };
      });
}

void clearDeviceChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_deviceChannel, null);
}

void resetCaches() {
  ClientIdentity.debugResetCache();
  DeviceInfo.debugResetCache();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    resetCaches();
    clearDeviceChannel();
  });

  test('用 ANDROID_ID 派生 client_id：卸载重装后不变', () async {
    mockAndroidDevice();
    SharedPreferences.setMockInitialValues({});
    resetCaches();

    final first = await ClientIdentity.id();
    expect(first, 'a_1a2b3c4d5e6f7a8b');
    expect(RegExp(r'^[0-9A-Za-z_-]{8,64}$').hasMatch(first), isTrue);

    // 模拟卸载重装：本地存储清空、内存缓存清空，但设备没换
    SharedPreferences.setMockInitialValues({});
    resetCaches();
    final afterReinstall = await ClientIdentity.id();

    expect(afterReinstall, first, reason: '同一台设备重装后 client_id 必须保持一致');
  });

  test('拿不到 ANDROID_ID 时退回随机 id，并在本地保持稳定', () async {
    clearDeviceChannel();
    SharedPreferences.setMockInitialValues({});
    resetCaches();

    final id = await ClientIdentity.id();
    expect(RegExp(r'^c_[0-9a-f]{32}$').hasMatch(id), isTrue);
    expect(await ClientIdentity.id(), id);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('client_id'), id);
  });

  test('老版本的随机 id 会迁移成设备派生 id（只迁一次）', () async {
    mockAndroidDevice(androidId: 'ffff000011112222');
    SharedPreferences.setMockInitialValues({'client_id': 'c_oldrandomid'});
    resetCaches();

    expect(await ClientIdentity.id(), 'a_ffff000011112222');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('client_id'), 'a_ffff000011112222');
  });

  test('全 0 / 太短的 ANDROID_ID 视为不可用，不拿它当标识', () async {
    mockAndroidDevice(androidId: '0000000000000000');
    SharedPreferences.setMockInitialValues({});
    resetCaches();
    expect(await ClientIdentity.id(), startsWith('c_'));

    mockAndroidDevice(androidId: 'abc');
    SharedPreferences.setMockInitialValues({});
    resetCaches();
    expect(await ClientIdentity.id(), startsWith('c_'));
  });

  test('设备名用品牌 + 型号，方便在设备列表里认手机', () async {
    mockAndroidDevice();
    resetCaches();
    expect(await ClientIdentity.label(), 'vivo V2025A · Android 15');
  });

  test('两台不同设备的 id 不同', () async {
    mockAndroidDevice(androidId: '1111111122222222');
    SharedPreferences.setMockInitialValues({});
    resetCaches();
    final a = await ClientIdentity.id();

    mockAndroidDevice(androidId: '3333333344444444');
    SharedPreferences.setMockInitialValues({});
    resetCaches();
    final b = await ClientIdentity.id();

    expect(a, isNot(b));
  });
}
