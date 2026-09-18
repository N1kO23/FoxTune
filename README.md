# FoxTune

Open source ECU tuning software for open source ECUs.

FoxTune targets [Speeduino](https://speeduino.com/) first, with rusEFI and MegaSquirt as later
goals. It runs on Linux, Windows, macOS and Android from a single Flutter codebase.

> **Status: early development.** Nothing here is safe to tune an engine with yet.

## Why

The practical alternative today is TunerStudio: closed source, paid for the useful tiers, and
desktop-only in practice. The open source field is thin, and there is no good mobile tuner at
all. FoxTune's clearest reason to exist is a phone plugged into the ECU with an OTG cable, in
the car, without a laptop.

## Design

FoxTune reads the ECU's **TunerStudio `.ini` definition** to learn page layout, scaling and
realtime data structure, rather than hardcoding them. That is what lets it survive firmware
updates and, eventually, speak to rusEFI - which ships INI files in the same format.

The core is **pure Dart with no Flutter dependency**:

| Package                      | Role                                                      |
| ---------------------------- | --------------------------------------------------------- |
| `packages/foxtune_ini`       | TunerStudio `.ini` parser -> typed ECU definition (M1 ✅) |
| `packages/foxtune_protocol`  | Speeduino serial codec: framing, CRC-32, pages, realtime  |
| `packages/foxtune_tune`      | Tune state, table/curve math, `.msq` import/export        |
| `packages/foxtune_transport` | Flutter `EcuLink` implementations (USB serial, USB OTG)   |
| `app/foxtune_app`            | Flutter UI                                                |

Those first three run under `dart test` with no ECU, no device and no display. Everything the
codec does sits above the `EcuLink` byte pipe, so it can be driven by an in-memory fake.

### Platform support

| Platform                | Transport                  | Status      |
| ----------------------- | -------------------------- | ----------- |
| Linux / Windows / macOS | USB serial (libserialport) | Planned, M2 |
| Android                 | USB OTG (USB host mode)    | Planned, M2 |
| iOS                     | WiFi bridge or BLE only    | Deferred    |

iOS exposes no generic USB serial API - the External Accessory framework requires Apple MFi
licensing - so an iPhone can only ever reach a Speeduino over WiFi (an ESP8266/ESP32 bridge on
the secondary serial port) or a BLE adapter. The transport layer is abstract so this can be
added without disturbing anything above it.

## Development

```sh
dart pub get      # resolve the core workspace
./tool/test.sh    # run core tests - no hardware needed
dart analyze
dart format .
```

`dart test` at the workspace root only sees the root package, so `tool/test.sh`
names each member package explicitly.

You do not need a Speeduino to work on the protocol layer. `foxtune_protocol` ships a
simulator, `FakeSpeeduino`, that speaks the real wire protocol over TCP - envelope, CRC-32,
page reads, realtime block and all. The integration tests drive a real `EcuClient` against it
over a real socket, so a framing mistake fails the build rather than passing quietly.

```dart
final ecu = FakeSpeeduino();
final port = await ecu.start();
final link = await SocketEcuLink.connect('127.0.0.1', port);
final id = await EcuClient(link).identify();
```

The desktop serial driver itself is the one part that cannot be tested this way: libserialport
rejects pseudo-terminals (`sp_get_port_by_name` returns `EINVAL` for `/dev/pts/*`), so a `socat`
loopback is not a usable stand-in for a real port. Verifying that layer needs real hardware, or
a tty0tty-style kernel module.

### The wire protocol

Two byte orders apply at once, and confusing them produces frames the ECU silently drops:

| Part                                             | Order             |
| ------------------------------------------------ | ----------------- |
| Envelope - length prefix, CRC-32                 | **Big**-endian    |
| Payload data - page ids, offsets, counts, values | **Little**-endian |

The length counts the payload only; the four CRC bytes sit outside it, and the CRC covers the
payload only. That means a corrupted length prefix is undetectable, so the decoder bounds it and
resynchronises rather than stalling.

## Safety

Writing a bad table to a running engine destroys hardware. FoxTune is read-only by default;
writes require an explicit mode toggle, are clamped to the bounds declared in the `.ini`,
are refused outright on a signature mismatch, and snapshot the tune to disk first.

## License

GPLv3 - see [LICENSE](LICENSE). This matches the Speeduino firmware's own license.
