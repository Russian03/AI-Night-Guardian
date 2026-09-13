#include <Arduino_Modulino.h>
#include <Arduino_RouterBridge.h>

ModulinoThermo thermo;
ModulinoLight light;

String read_sensors() {
  light.update();

  String data = "{";
  data += "\"temp_c\":";
  data += String(thermo.getTemperature(), 2);
  data += ",\"humidity\":";
  data += String(thermo.getHumidity(), 2);
  data += ",\"lux\":";
  data += String(light.getLux());
  data += "}";

  return data;
}

void setup() {
  Serial.begin(115200);

  Modulino.begin();
  thermo.begin();
  light.begin();

  Bridge.begin();
  Bridge.provide("read_sensors", read_sensors);

  Serial.println("Sensores y bridge iniciados");
}

void loop() {
  light.update();
  delay(2000);
}