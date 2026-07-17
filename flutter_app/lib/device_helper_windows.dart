import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:win32audio/win32audio.dart';

Future<List<Map<String, String>>> getOutputDevices() async {
  if (!Platform.isWindows) return [];
  try {
    final devices = await Audio.enumDevices(AudioDeviceType.output) ?? [];
    return devices.map((d) => {
      'id': d.id,
      'name': d.name,
    }).toList();
  } catch (e) {
    debugPrint('Error listing output devices: $e');
    return [];
  }
}

Future<void> selectOutputDevice(String id) async {
  if (!Platform.isWindows) return;
  try {
    await Audio.setDefaultDevice(
      id,
      console: true,
      multimedia: true,
      communications: true,
    );
  } catch (e) {
    debugPrint('Error setting default output device: $e');
  }
}
