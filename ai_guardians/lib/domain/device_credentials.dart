class DeviceCredentials {
  final String deviceId;
  final String provisioningKey;
  final String? model;
  final String? fwMinVersion;

  DeviceCredentials({
    required this.deviceId,
    required this.provisioningKey,
    this.model,
    this.fwMinVersion,
  });

  factory DeviceCredentials.fromJson(Map<String, dynamic> json) {
    return DeviceCredentials(
      deviceId: json['device_id'] as String,
      provisioningKey: json['provisioning_key'] as String,
      model: json['model'] as String?,
      fwMinVersion: json['fw_min_version'] as String?,
    );
  }
}