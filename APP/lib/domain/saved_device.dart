class SavedDevice {
  final String deviceId;
  final String roomName;

  SavedDevice({required this.deviceId, required this.roomName});

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'roomName': roomName,
  };

  factory SavedDevice.fromJson(Map<String, dynamic> json) => SavedDevice(
    deviceId: json['deviceId'] as String,
    roomName: json['roomName'] as String,
  );
}