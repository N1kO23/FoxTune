## 0.1.0

Speeduino serial protocol codec.

- `EcuLink`, the byte-pipe seam the whole codec sits above, with an in-memory
  fake for tests.
- `msEnvelope_1.0` framing: big-endian length and CRC-32 around little-endian
  payload data, with a streaming decoder that bounds implausible lengths and
  resynchronises rather than stalling.
- `EcuClient`: handshake, page reads chunked to the blocking factor, realtime
  reads, per-command timeouts and retry on a `busy` reply.
- `RealtimeDecoder`: decodes the realtime block into named, scaled values using
  the definition's `[OutputChannels]`, including computed channels.
- `RealtimeMonitor`: paced polling that waits for each reply before scheduling
  the next, and reports the rate actually achieved.
- `SocketEcuLink` for an ESP8266/ESP32 WiFi bridge.
- `FakeSpeeduino`, a simulator speaking the real wire protocol over TCP.
