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

| Package                      | Role                                                     |
| ---------------------------- | -------------------------------------------------------- |
| `packages/foxtune_ini`       | TunerStudio `.ini` parser -> typed ECU definition        |
| `packages/foxtune_protocol`  | Speeduino serial codec: framing, CRC-32, pages, realtime |
| `packages/foxtune_tune`      | Tune state, table/curve math, `.msq` import/export       |
| `packages/foxtune_transport` | Flutter `EcuLink` implementations (USB serial, USB OTG)  |
| `app/foxtune_app`            | Flutter UI                                               |

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

You do not need a Speeduino to work on the protocol layer. Use
[speeduino-serial-sim](https://github.com/askrejans/speeduino-serial-sim) over a `socat` PTY
pair:

```sh
socat -d -d pty,raw,echo=0 pty,raw,echo=0
```

## Safety

Writing a bad table to a running engine destroys hardware. FoxTune is read-only by default;
writes require an explicit mode toggle, are clamped to the bounds declared in the `.ini`,
are refused outright on a signature mismatch, and snapshot the tune to disk first.

## License

GPLv3 - see [LICENSE](LICENSE). This matches the Speeduino firmware's own license.
