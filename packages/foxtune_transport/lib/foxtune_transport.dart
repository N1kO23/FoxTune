/// Flutter implementations of `EcuLink`.
///
/// Desktop (Linux/Windows/macOS) uses libserialport; Android uses USB host
/// mode over OTG. A TCP implementation for the ESP8266/ESP32 WiFi bridge - the
/// only route that also works on iOS - and BLE come later.
library;

// Transport implementations land in M2.
