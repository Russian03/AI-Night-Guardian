#include <Arduino_Modulino.h>
#include <Arduino_RouterBridge.h>
#include <zephyr/zephyr.h>
#include <zephyr/drivers/i2s.h>

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

  if (!I2S.begin(I2S_PHILIPS_MODE, 16000, 32)) {
    Serial.println("Error al iniciar el microfono");
    while (1);
  }

  Serial.println("Sensores y bridge iniciados");
}

void loop() {
  light.update();

  Serial.print("Temperatura: ");
  Serial.print(thermo.getTemperature());
  Serial.print(" C | Humedad: ");
  Serial.print(thermo.getHumidity());
  Serial.print(" % | Lux: ");
  Serial.println(light.getLux());
  int32_t muestra_audio = I2S.read();
  if (muestra_audio) {
    Serial.println(muestra_audio);
  }

  delay(2000);
}