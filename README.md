# FoxTune

Open source ECU tuning software for open source ECUs.

FoxTune targets [Speeduino](https://speeduino.com/) first, with rusEFI and MegaSquirt as later
goals. It runs on Linux, Windows, macOS and Android from a single Flutter codebase.

> **Status: works, but unproven on hardware.** Everything below is implemented and tested
> against a protocol-accurate simulator. None of it has yet talked to a real Speeduino, so
> treat the write path in particular as unverified - see [Safety](#safety).

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

| Package                      | Role                                                               |
| ---------------------------- | ------------------------------------------------------------------ |
| `packages/foxtune_ini`       | TunerStudio `.ini` parser, preprocessor and expression evaluator   |
| `packages/foxtune_protocol`  | Speeduino serial codec, realtime decoding, and the ECU simulator   |
| `packages/foxtune_tune`      | Tune state, table maths, `.msq` files, datalogging, the write path |
| `packages/foxtune_transport` | Flutter `EcuLink` implementations (USB serial, USB OTG, TCP)       |
| `app/foxtune_app`            | Flutter UI: gauges, table editor, 3D surface, logging              |

Those first three run under `dart test` with no ECU, no device and no display. Everything the
codec does sits above the `EcuLink` byte pipe, so it can be driven by an in-memory fake.

### Platform support

| Platform           | Transport                       | Status                      |
| ------------------ | ------------------------------- | --------------------------- |
| Linux              | USB serial, TCP                 | Built and run               |
| Android            | USB OTG, TCP                    | Built and run; OTG untested |
| Windows / macOS    | USB serial, TCP                 | Should build; never tried   |
| Any, including iOS | TCP (ESP8266/ESP32 WiFi bridge) | Works                       |
| iOS                | BLE                             | Not started                 |

iOS exposes no generic USB serial API - the External Accessory framework requires Apple MFi
licensing - so an iPhone can only ever reach a Speeduino over WiFi (an ESP8266/ESP32 bridge on
the secondary serial port) or a BLE adapter. The transport layer is abstract so this can be
added without disturbing anything above it.

## What works

|                   |                                                                                                                                                    |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Connect**       | USB serial or TCP, with a signature check against the loaded definition                                                                            |
| **Dashboard**     | Live gauges and status lamps, decoded from `[OutputChannels]` at ~30 Hz                                                                            |
| **Tables**        | Editable grid with keyboard navigation, interpolate, smooth, scale                                                                                 |
| **Live position** | The operating cell ringed, the four interpolation neighbours marked, and a dot at the exact interpolated point - in the grid and on the 3D surface |
| **3D surface**    | Orbitable isometric mesh, no GL dependency                                                                                                         |
| **Writing**       | Write to RAM, verify by the ECU's own page CRC, then burn                                                                                          |
| **Tune files**    | `.msq` read and write, matched by name                                                                                                             |
| **Logging**       | MegaLogViewer-compatible `.msl`, columns from `[Datalog]`                                                                                          |

Not yet: curve editing, a settings screen (the temperature scale is fixed to Celsius in code),
generated UI from the definition's `[Menu]`, and rusEFI support.

## Building

See **[BUILDING.md](BUILDING.md)** for prerequisites, per-platform notes and troubleshooting.

Two things that trip people up: Dart commands run from the repository root while Flutter
commands run from the package directory, and the Android build is deliberately pinned to
Gradle 8.

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

```sh
cd packages/foxtune_tune
dart run bin/fake_ecu.dart --msq /path/to/your-tune.msq
```

Then connect from the app with **Network ECU** → `127.0.0.1:2000`. The simulator drives a
plausible running engine into the realtime block - idle, a pull to redline, a cruise, then a
closed-throttle overrun - so gauges move, the live table cursor travels across cells, and the
warning thresholds are actually reached. `--static` disables it; `--ini PATH` uses a different
definition.

Pass a tune with `--msq`. Without one the simulator serves empty pages, and channels whose
scaling depends on a configuration constant - the VE table's load axis among them - cannot be
written at all. It prints a warning naming any it could not scale.

In tests it is used directly:

```dart
final ecu = FakeSpeeduino(channels: definition.outputChannels)..simulateEngine();
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

## Computed channels

Several primary readings are not transmitted at all. The definition describes how to derive
them - `coolant = { coolantRaw - 40 }`, `lambda = { afr / stoich }` - so FoxTune evaluates
those expressions rather than hardcoding the arithmetic. Without this a dashboard could not
show coolant or intake temperature, and switching the definition between Celsius and
Fahrenheit would silently report the wrong number.

Expressions that use functions FoxTune does not implement evaluate to `null`, and that
propagates: a gauge reads as unavailable rather than showing a fabricated value.

## Datalogging

FoxTune records to MegaLogViewer-compatible `.msl` - a tab-separated file with the column
names, order and number formats taken from the definition's own `[Datalog]` section, because
tools like MegaLogViewer key off specific column names.

Two things it deliberately does not do: it does not invent a zero for a reading that is
absent (the cell is left blank so a plot shows the gap), and it does not create columns that
would be blank for the entire log - a channel the ECU cannot report, or one whose `[Datalog]`
condition is false, is left out and listed instead. Rows are flushed as they are recorded, so
a log survives the session ending abruptly, which is when it matters most.

## Table files

Individual tables import and export as TunerStudio `.table` files - a
`<tableData>` document holding one table's axes and values, as opposed to `.msq`, which
carries a whole tune. Useful for moving a VE or spark map between tunes without touching
anything else.

An import whose shape matches is copied cell for cell, optionally bringing its axis bins with
it. An import of a _different_ shape is interpolated onto the destination's axes, since
importing a 12×12 into a 16×16 is a normal thing to want; values outside the source's range
hold at its edge rather than being extrapolated. Everything is clamped to what the definition
permits, and nothing reaches the ECU until you burn.

## Tune files

FoxTune reads and writes TunerStudio `.msq` files. Values are matched **by name**, not by
offset, so a tune saved from a different firmware version loads whatever still applies and
reports the rest rather than silently shifting everything. A signature mismatch has to be
confirmed explicitly.

Loading a `.msq` only changes the in-memory tune. Nothing reaches the ECU until you burn, so
the guard rails below stay in one place.

## Temperature scale

The definition computes `coolant` and `iat` with _different expressions_ depending on whether
it is parsed with `CELSIUS` defined. That makes the scale a parsing decision, not a display
one: choosing it wrong does not mislabel a number, it produces a different number. FoxTune
ties the choice, the parse and the gauge thresholds to a single `TemperatureUnit` so they
cannot drift apart. It defaults to Celsius and is not yet exposed in the UI.

## Safety

Writing a bad table to a running engine destroys hardware, so writing is something a session
has to _earn_:

1. **Refused by default.** Read-only unless the signature matches the loaded definition _and_
   write mode has been switched on deliberately. Write mode resets on every disconnect.
2. **Clamped.** Every value is pinned to the `lo`/`hi` bounds the definition declares before it
   reaches the wire, and again to what the storage type can hold - 256 wrapping to 0 in a `U08`
   would turn a rich cell into a lean one.
3. **Snapshotted.** A restore point is written to disk before the first write of a session.
4. **Verified before it is permanent.** Each page is written to RAM, then the ECU is asked for
   that page's own CRC-32. Only on a match is it burned to EEPROM. RAM can be rewritten; a
   corrupt page burned to EEPROM is what strands someone at the roadside.

## License

GPLv3 - see [LICENSE](LICENSE). This matches the Speeduino firmware's own license.
