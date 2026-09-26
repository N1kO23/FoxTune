<!-- markdownlint-disable MD033 - Markdown has no image that follows the reader's theme -->
<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo/svg/foxtune-horizontal-dark.svg">
    <img alt="FoxTune" src="branding/logo/svg/foxtune-horizontal-light.svg" width="400">
  </picture>
</h1>
<!-- markdownlint-enable MD033 -->

Open source ECU tuning software for open source ECUs.

FoxTune tunes [Speeduino](https://speeduino.com/) and [rusEFI](https://rusefi.com/), with
MegaSquirt a later goal. It runs on Linux, Windows, macOS and Android from a single Flutter
codebase.

> **Status: works; tuning a real Speeduino over USB is proven.** Everything below is
> implemented and tested against a protocol-accurate simulator. On a real Speeduino, over USB
> serial, FoxTune has connected, shown the live dashboard, changed settings, and written,
> verified and burned the tune. Not yet tried on hardware: autotuning, sensor calibration, the
> trigger loggers, USB OTG on Android, and network (TCP) bridges - treat those as unverified,
> and see [Safety](#safety). rusEFI has been read, edited, verified and burned against rusEFI's
> own simulator - the real firmware, built for a PC - but not yet against a rusEFI board.

## Why

The practical alternative today is TunerStudio: closed source, paid for the useful tiers, and
desktop-only in practice. The open source field is very thin.
FoxTune's clearest reason to exist is a phone or tablet plugged into the ECU with an OTG cable, in
the car, eliminating the need of a laptop, although laptop still offers keyboard bindings.

FoxTune is intended to not be tied to a single ECU branch. It also aims to bridge similar style UI
for both desktop and mobile tuning.

## Why not

TunerStudio is a robust software with proper tech support for it and if you don't mind having
licensed closed source software, it is very good and gets the job done. On the mobile there also
is ECU Manager, a pretty good and polished tuning software for Speeduino.

FoxTune's goal is to not replace TunerStudio and in fact I highly encourage people to use it
and support its creators, it's **way** more ironed out. FoxTune also won't implement offline tuning,
at least for the time being, if you want to adjust your tune while not hooked to the ECU, then you 
are out of luck. That being said, FoxTune comes with **no warranty**, if you ECU and/or anything tied 
to it (including, but not limited to, engine) breaks or gets damaged due to an issue with FoxTune 
(such as a software bug, miscommunication with ECU, corrupted write, etc), I take no responsibility. 
If you want a known good and stable tuning software, use TunerStudio.

**Use FoxTune at your own risk!**

## Design

FoxTune reads the ECU's **TunerStudio `.ini` definition** to learn page layout, scaling,
realtime data structure and even the commands that address them, rather than hardcoding them.
That is what lets it survive firmware updates and speak to both Speeduino and rusEFI, which ship
definitions in the same format.

The core is **pure Dart with no Flutter dependency**:

| Package                      | Role                                                               |
| ---------------------------- | ------------------------------------------------------------------ |
| `packages/foxtune_ini`       | TunerStudio `.ini` parser, preprocessor and expression evaluator   |
| `packages/foxtune_protocol`  | Serial codec, realtime decoding, simulated Speeduino and rusEFI    |
| `packages/foxtune_tune`      | Tune state, table and curve maths, autotuning, `.msq`, datalogging |
| `packages/foxtune_transport` | Flutter `EcuLink` implementations (USB serial, USB OTG, TCP)       |
| `app/foxtune_app`            | Flutter UI: gauges, table editor, 3D surface, settings, logging    |

Those first three run under `dart test` with no ECU, no device and no display. Everything the
codec does sits above the `EcuLink` byte pipe, so it can be driven by an in-memory fake.

### Platform support

| Platform | Transport                       | Status                                                  |
| -------- | ------------------------------- | ------------------------------------------------------- |
| Linux    | USB serial, TCP                 | Built and run                                           |
| Windows  | USB serial, TCP                 | Built and run                                           |
| Android  | USB OTG, TCP                    | Built and run; TCP used with the simulator, OTG untried |
| macOS    | USB serial, TCP                 | Should build; never tried                               |
| Any      | TCP (ESP8266/ESP32 WiFi bridge) | Works with the simulator; not yet with a real bridge    |
| iOS      | BLE                             | Not started                                             |

On Android, plugging a Speeduino in offers to open FoxTune; ticking "always" stops the USB
permission prompt from coming back. The screen stays on while connected, unless App settings say
otherwise. A pulled cable is noticed at once and reported as a lost connection, and any edits not yet burned are kept so they
can be saved as a `.msq`. Tunes, table exports and datalogs leave the phone through Android's own
"Save to" picker. [BUILDING.md](BUILDING.md#testing-on-a-phone) has the checklist for trying
it on a real phone.

A serial link runs at 115200 baud, as Speeduino's does over USB, and waits a second after the
port opens for an Arduino Mega to restart. Both are in **App settings** - the gear at the end of
the top bar - for a Bluetooth module set to another speed or a board that does not restart,
along with how often live data is read. So are the theme, the temperature scale and the
wallpaper behind the main screen: the FoxTune emblem as a faint watermark by default, an image
of your own, or none. And so are the colours the maps are shaded in - on the grid, the 3D
surface and autotune's coverage - as a gradient of as many colours as you like, from built-in
presets or your own saved ones; the numbers on it turn black or white wherever that reads
better. So is how the dashboard's gauges look - see [Dashboard](#dashboard).

iOS exposes no generic USB serial API - the External Accessory framework requires Apple MFi
licensing - so an iPhone can only ever reach a Speeduino over WiFi (an ESP8266/ESP32 bridge on
the secondary serial port) or a BLE adapter. The transport layer is abstract so this can be
added without disturbing anything above it.

## What works

|                   |                                                                                                                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Connect**       | Speeduino and rusEFI over USB serial or TCP; the exact firmware's definition found, downloaded or chosen, and checked                                                                      |
| **Dashboard**     | Pages of dials, bars, readouts, lamps and time graphs you arrange, from any gauge or live channel; limits follow Gauge Limits or your own; styled by a default look any gauge can override |
| **Tables**        | Editable grid with keyboard navigation, interpolate, smooth, scale                                                                                                                         |
| **Settings**      | Trigger setup, engine constants, ASE, WUE and the rest - screens generated from the definition's `[Menu]` and `[UserDefined]`, not hand-written                                            |
| **Curves**        | Editable point list and plot, with the live operating point marked                                                                                                                         |
| **Calibration**   | Coolant, air and O2 sensor tables made from the definition's own choices, checked by the ECU's checksum; TPS from the sensor                                                               |
| **Trigger logs**  | Tooth and composite loggers from `[LoggerDefinition]`: tooth times as bars with the gap picked out, edges as traces, CSV                                                                   |
| **Autotune**      | VE table tuned against the AFR/lambda target from live wideband data, filtered by the definition's own `[VeAnalyze]` rules                                                                 |
| **Live position** | The operating cell ringed, the four interpolation neighbours marked, and a dot at the exact interpolated point - in the grid and on the 3D surface                                         |
| **3D surface**    | Orbitable isometric mesh, no GL dependency                                                                                                                                                 |
| **Writing**       | Write to RAM, verify by the ECU's own page CRC, then burn                                                                                                                                  |
| **Tune files**    | `.msq` read and write, matched by name                                                                                                                                                     |
| **Logging**       | MegaLogViewer-compatible `.msl`, columns from `[Datalog]`                                                                                                                                  |

Not yet: autotuning on rusEFI, rusEFI's bench tests and Lua, a sensor calibration from an `.inc`
file, replaying a recorded `.msl` log into the autotuner, warmup autotuning, `commandButton`
actions, TunerStudio's SD card browser, and the `string` PC variables used for auxiliary-channel
aliases.

## Building

See **[BUILDING.md](BUILDING.md)** for prerequisites, per-platform notes and troubleshooting.

Two things that trip people up: Dart commands run from the repository root while Flutter
commands run from the package directory, and the Android build's Gradle versions follow Flutter's
own template, so they move with Flutter rather than ahead of it.

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
over a real socket, so a framing mistake fails ->he build rather than passing quietly.

```sh
cd packages/foxtune_tune
dart run bin/fake_ecu.dart --msq /path/to/your-tune.msq
```

Then connect from the app with **Network ECU** -> `127.0.0.1:2000`. Pass a rusEFI definition
with `--ini` and it is a simulated rusEFI instead, on port 29001, with canned fuelling - the
tune-driven engine described below is Speeduino's. It drives a plausible
running engine into the realtime block - idle, a pull to redline, a cruise, then a
closed-throttle overrun - so gauges move, the live table cursor travels across cells, and the
warning thresholds are actually reached. `--static` disables it; `--ini PATH` uses a different
definition.

**The engine runs on the tune.** The VE table in the ECU's own pages decides how much fuel goes
in; a hidden airflow model decides how much the engine needed; the wideband reports the
difference through a sensor lag. So editing the VE table in FoxTune changes what the simulated
engine runs at, closed-loop correction trims against it, warmup and afterstart enrichment come
off the tune's own curves, ignition advance comes off the spark table, and the overrun cuts
fuel. Autotuning can be driven end to end without an engine.

Fuelling is defined so that a VE table equal to the engine's airflow lands exactly on the AFR
target - which is what "a correct VE table" means to a tuner, and what autotuning is trying to
reach.

Pass a tune with `--msq` for realistic tables and settings. Without one the pages hold filler
bytes, which are not a tune - the axis bins are not even monotonic - so a base tune is seeded
instead: real axes, a VE table taken from the engine model, a flat mixture target, an ignition
map and the enrichment curves. `--ve-error PERCENT` sets how far out the seeded VE table
starts, which is what gives autotuning something to correct (default -8%).

In tests it is used directly:

```dart
final ecu = FakeSpeeduino(channels: definition.outputChannels)..simulateEngine();
final port = await ecu.start();
final link = await SocketEcuLink.connect('127.0.0.1', port);
final id = await EcuClient(link).identify();
```

`FakeSpeeduino` alone fuels the engine from a canned curve, which is all the protocol tests
need. For the tune-driven model, hand it a `TunedEngineSimulation` from
`package:foxtune_tune/simulation.dart`:

```dart
final engine = TunedEngineSimulation(definition: doc, pages: ecu.pages)
  ..seedTune(errorPercent: -10);
ecu.simulateEngine(simulation: engine);
```

It lives in `foxtune_tune` rather than beside `FakeSpeeduino` because it reads the ECU's pages
through `TableView` and `CurveView`, and `foxtune_protocol` sits below those.

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

## rusEFI

rusEFI speaks the same TunerStudio protocol and ships its definitions in the same format, so
most of FoxTune works on it unchanged: its dashboard is built from its own front page, its
settings screens and tables are generated from its own menus. What differs is handled by
reading the definition more completely rather than by rusEFI-specific code.

**Finding the definition.** rusEFI generates a definition for every board and every build, and
its signature ends in a hash of the settings layout - so it has to be the exact one. On
connecting, FoxTune looks in order for:

1. the Speeduino definition it ships with;
2. one kept on this device - from an earlier connection, or added ahead of time;
3. the one the firmware project publishes for that build: for rusEFI, at a rusefi.com address
   spelled out by the signature; for a Speeduino release, the newest point release of it on
   speeduino.com, where SpeedyLoader gets its firmware;
4. failing those, a file you choose - from the firmware bundle for your board, the drive a
   rusEFI ECU mounts over USB (`rusefi.ini.zip`), or a firmware you built yourself.

A downloaded or chosen definition must match the ECU's signature exactly, and is kept so it is
not asked for again. A Speeduino development build is not published: choose its definition
(`reference/speeduino.ini` in its source) and it is kept.

**ECU definitions**, in App settings, lists every definition FoxTune has and where each came
from, and adds, removes or saves a copy of one. It downloads ahead of time too: any Speeduino
version from speeduino.com's list, or a rusEFI build by its signature - rusEFI publishes one per
board and build, so there is no list to choose from. A definition kept before heading somewhere
without internet lets the ECU it is for connect there. Automatic downloads are switched on or
off there for each firmware; the Download button beside an ECU that needs its definition still
fetches one when asked.

**Commands from the definition.** Page reads, writes, burns, CRC checks and live data are sent
as the definition's own templates - `R%2i%2o%2c` for a rusEFI page read, `p%2i%2o%2c` for a
Speeduino's - with pages addressed by the bytes its `pageIdentifier` gives. rusEFI's live data is
larger than one transfer and is read in pieces; its two working-memory pages declare no burn
command and are never burned. It stores hundreds of settings and most live channels as 32-bit
floats, which are kept as floats throughout - a lambda of 0.98 reads 0.98.

**The handshake.** Both firmwares answer `S`, with different things: rusEFI with its
signature, Speeduino with its display string. So FoxTune sends `S` first and follows up with
`V` (rusEFI's version) or `Q` (Speeduino's signature). Getting this right also fixed a Speeduino
bug: FoxTune used to take the reply to `S` as the signature, so a real Speeduino - which
answers `Q` with it - always reported a definition mismatch, and writing stayed disabled. The
simulated Speeduino had copied the mistake, which is why no test caught it.

**How far it has been tested.** Against rusEFI's own simulator, built from rusEFI master of
2026-09-21: identified; definition downloaded from rusefi.com and matched; all five pages read
(27 KB) and each confirmed by the ECU's own CRC; live data decoded; a VE cell edited, written,
verified, burned, read back after reconnecting, and restored. The simulator answers every
request about 40 ms late, whoever asks, so live data from it runs at about 7 samples a second;
that is the simulator, not the link. Not yet: a rusEFI board, autotuning (its `[VeAnalyze]`
rules have not been checked, so it is not offered), rusEFI's bench tests and Lua, and running
its trigger loggers - they are offered, decoded from its definition, but have not been run
against its simulator.

## Computed channels

Several primary readings are not transmitted at all. The definition describes how to derive
them - `coolant = { coolantRaw - 40 }`, `lambda = { afr / stoich }` - so FoxTune evaluates
those expressions rather than hardcoding the arithmetic. Without this a dashboard could not
show coolant or intake temperature, and switching the definition between Celsius and
Fahrenheit would silently report the wrong number.

Expressions that use functions FoxTune does not implement evaluate to `null`, and that
propagates: a gauge reads as unavailable rather than showing a fabricated value.

## Dashboard

The dashboard is pages of gauges you arrange: tabs such as "Driving" or "Tuning", each a grid
you add gauges to, drag them around and resize them on. A page scales to the screen as a whole,
so it keeps its shape everywhere - larger or smaller, never rearranged.

Each page has a **width** - phone, tablet, laptop or large monitor, one to four phone widths
across - and a **grid size**. A wider page holds more gauges side by side at the same size rather
than drawing the same gauges bigger; on a screen narrower than the page, the whole page shrinks
to fit, so a phone-width page is the one to use on a phone. A finer grid moves and sizes gauges in
smaller steps without changing how big they are. Neither setting moves a gauge that still fits.

Nothing about a gauge is typed into FoxTune. Which gauges exist, their ranges, their warning and
danger points, their units and precision all come from the definition's
`[GaugeConfigurations]`, and the first page starts as its `[FrontPage]` plus the AFR and a few
readouts it leaves off. Where a limit is an expression it is evaluated each time the gauge is
drawn - and the tachometer's are exactly the Gauge Limits settings (`{rpmwarn}`, `{rpmdang}`,
`{rpmhigh}`), so the RPM gauge warns where the tuner said it should. Indicators are the front
page's own, lit in the colours it gives them.

Every live channel can go on a page, not just the ones with a gauge definition: the picker's
**Channels** tab lists the rest, numbers and single status bits (shown as lamps) alike. The
definition gives those no range and no alarms, so they start as digital readouts.

Any gauge's range, warning and danger points and decimals can be set by hand - to give a bare
channel a range, or to overrule the definition. Limits belong to the gauge, not to one
placement of it, so they apply on every page and in every graph lane. Setting them on a gauge
whose limits are tune settings, like the tachometer's, fixes them and they stop following Gauge
Limits; the editor says so first.

Where a definition's alarm points contradict each other, FoxTune ignores them rather than guess.
Speeduino's has eight gauges copied from one line - danger below 130, warning below 140 _and_
above 140 - so no reading is ever normal and warmup enrichment shows DANGER at 100%, which is
where it sits on every warm engine. Its free-memory gauge does the same with its high bands
reversed. Those gauges show without alarms until you set your own.

A reading has to go past a limit to trip it; sitting on one is fine. And zero, on a gauge whose
scale starts at zero, is never a low alarm: a closed throttle, the injectors off in fuel cut or a
stopped engine is the thing at rest, not a reading sagging too low, though the definition's low
limits would flag all three. A reading just above zero still alarms, and so does the bottom of a
scale that does not start at zero - a coolant sensor reading -40 has usually lost its wire.

Any numeric gauge can be a dial, a bar, a digital readout or a time graph. A time graph shows up
to four channels as **lanes** sharing a time axis, each against its own scale, rather than lines
overlaid on one plot: RPM runs to thousands and AFR to fifteen, and giving each line its own
scale on a shared axis would make how high a line sits mean something different for every line.

How the gauges look is a setting of its own, in **App settings -> Gauge appearance**. Dials
come with an arc or a needle, a sweep from 180° to 300°, and ticks or numbers along the scale;
bars run across, upright or in blocks; readouts come with or without their card; graphs can be
shaded under the trace; lamps are pills, squares or plain - and the colours of all of them can be
chosen, warning and danger included. That look is the default every gauge follows. Any one gauge
can change any part of it from its options while the page is being edited, and whatever it
leaves at Default keeps following the default, including when the default changes later. The
default is the same for every ECU; a gauge's own look is kept with its layout. However the
colours are set, an alarm still shows its icon and word, so a warning recoloured to look like a
normal reading still reads as a warning.

Layouts are saved per ECU family as they are edited. A gauge the current definition no longer
has - from a different firmware - keeps its place and says so, rather than vanishing.

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

## Settings screens

Trigger setup, engine constants, injector characteristics, warmup and afterstart enrichment -
most of what a tune actually is, beyond its tables - are **generated from the definition**
rather than written by hand. The shipped `speeduino.ini` declares 116 menu entries and 240
dialogs holding around a thousand fields; hand-building those would be a week's work that went
stale on the next firmware release.

Each field's control comes from its own declaration: a bitfield becomes a drop-down of the
option labels the definition lists, a scalar a numeric entry carrying its units and declared
bounds. Bitfield writes merge, so changing the injector layout does not disturb the injector
pairing packed into the same byte.

The `{ ... }` conditions are what make a screen like Trigger Setup usable at all: choose a
missing-tooth wheel and the tooth-count fields become editable, choose a distributor and they
grey out. Those expressions are evaluated against the tune and, where they ask what the engine
is doing right now, against the realtime feed. A condition that cannot be answered shows the
field rather than hiding it - a screen that concealed its contents until the engine was running
would be useless on the bench.

The definition keeps two menus over the same tables: the tuning menus open a table's grid, and
"3D Tuning Maps" opens its surface. That is a real distinction rather than a duplicate, so a map
entry opens a full-window surface with no grid under it, and a button back to the grid for
editing - there is no sane way to drag a value on an isometric mesh.

One panel is built by hand. A dialog line like `panel = std_injection` tells TunerStudio to draw
one of its **own** built-in panels there, and the definition says nothing about what is inside.
Speeduino's Engine Constants embeds `std_injection`, which is the only place nine core settings
can be edited at all: required fuel, fuel load source, squirts per engine cycle, injector
staging, engine stroke, number of cylinders and injectors, injector port type and engine type.
FoxTune draws that panel itself, from the same controls as a generated dialog - so bounds, option
labels and help text still come from the definition. **Squirts per engine cycle** is offered as a
choice of counts that divide the cylinder count evenly, because the firmware stores it the other
way up (`divider`, cylinders per squirt, used as `nSquirts = nCylinders / divider` in integer
arithmetic). A test fails if a dialog embeds a built-in panel FoxTune neither draws nor has
deliberately left out.

Some things are deliberately left out. `commandButton` entries render disabled: they fire
actions at the ECU, several of which start a calibration, and shipping an untested write path
to hardware is not worth the completeness. The same goes for the real-time clock panel
(`std_ms3Rtc`), whose one job is sending the ECU a new time, and TunerStudio's SD card browser.
TunerStudio's sensor calibration wizards are FoxTune's own - see
[Sensor calibration](#sensor-calibration).

Gauge limits and a few similar values are `[PcVariables]`: they live on the tuning computer
rather than on the ECU, are seeded from the definition's factory values, and are marked as such
in the UI. They are not burned; FoxTune keeps them on the device between sessions, per ECU family,
so a firmware update does not reset them.

## Sensor calibration

Speeduino keeps its coolant, air temperature and O2 sensor calibrations outside its pages, as
tables TunerStudio makes with wizards of its own. The definition's `[ReferenceTables]` says what
they can be made from, and FoxTune's Tools menu offers the same choices:

- **Temperature sensors**: a thermistor the definition lists (GM, Bosch, Ford...) or three points
  of your own, fitted with the Steinhart-Hart equation. The table is 32 values from 0 V to 5 V,
  in tenths of a degree Fahrenheit, as the firmware expects. Values outside the definition's
  limits - an open or shorted sensor - hold its fallback instead, as TunerStudio does.
- **The O2 sensor**: a wideband controller's formula from the definition, or a straight line
  through two points of your own - 1024 values of AFR. A formula that reads its table from an
  `.inc` file is shown but cannot be chosen yet.
- **The throttle position sensor**: `tpsMin` and `tpsMax`, the closed and wide-open readings,
  each taken from the live reading or typed in. TunerStudio offers this without the definition
  describing it, so FoxTune adds it to the same menu. These are ordinary changes to the tune,
  and are burned with it.

The ECU saves a calibration the moment it arrives - there is no burn step - so sending one
needs write mode and is confirmed first. It is sent as the firmware reads it (`comms.cpp`), not
by rendering the definition's `tableWriteCommand`, whose `%2i` and byte order do not match what
the firmware takes. It goes in pieces of the definition's `tableBlockingFactor` exactly: up to
202305, the firmware saves the O2 table only when the piece that starts where its own chunking
puts the last one arrives. Afterwards the ECU is asked for the CRC-32 it keeps of what it saved,
and that is compared with the table sent. The same checksum tells which of the choices the ECU
has now. Speeduino before 202501 kept a broken checksum for the O2 table, so there it is sent
without that check.

Calibrations are sent only to a Speeduino: another ECU with `[ReferenceTables]` lays the command
out differently, and it has not been tried.

## Trigger logs

The Triggers tab runs the ECU's own tooth and composite loggers, as `[LoggerDefinition]`
describes them, to show what the ECU sees of the trigger wheel. A tooth log is the time from
each tooth to the next, drawn as bars: on a missing-tooth wheel the gap should be the one tall
bar, once a turn. A composite log is every edge on the trigger inputs, drawn as a trace per
input, which shows where the cam falls against the crank.

The commands, the flag that says a capture is ready, and the layout of each record all come
from the definition. A record is read as one big-endian number with bit 0 the lowest bit of its
last byte - how both Speeduino and rusEFI lay them out. FoxTune watches the ready flag in the
live data it already polls, and reads each capture once it is set; after the definition's
timeout it reads what there is, which from an engine that is not turning is nothing. Speeduino
pads a capture it has not filled, and the padding is left out. A capture can be saved as CSV.

A logger runs until stopped, and stops when you leave the tab or disconnect: Speeduino's takes
over the trigger inputs' interrupts while it runs, so it is not left running.

**How far they have been tested.** Both, against the simulated Speeduino, which keeps
calibrations as the firmware does and runs its loggers on a simulated 36-1 wheel. Not yet: a
real Speeduino, and rusEFI's loggers, which are decoded from its definition but have not been
run against its simulator.

## Autotuning

The VE table can be tuned from live wideband data: compare what the engine actually ran against
the AFR (or lambda) target table at the operating point, and move the cells that are wrong.

The arithmetic is the easy half. Nearly all of the work is deciding when a reading is telling
the truth about the steady state of the fuel table rather than about something else the engine
was doing - and the definition already says. `[VeAnalyze]` names the table to tune, the target,
the measured channel and the closed-loop trim channel, all of which swap between AFR and lambda
with the build, plus the filters: minimum coolant temperature, the acceleration-enrichment and
afterstart flags, the overrun, and the table's own axis limits. Those come from the file rather
than from guesswork, so they follow a firmware release.

One filter is FoxTune's own. Exhaust gas takes time to reach the sensor, so a reading describes
combustion that already happened; a sample taken mid-transition would be credited to whichever
cell the engine has moved into. The operating point must hold still for a settling time before
anything counts.

Each accepted sample yields a correction ratio - `(measured ÷ target) × (closed-loop trim ÷
100)`, so a trim already adding fuel is read as the table being low rather than tuned against -
spread over the four cells the ECU interpolates between. A cell moves once it has enough
evidence, by a bounded step, and never further from where it started than the session limit.
Corrections are written as a percentage of the cell's starting value, so repeated rounding
cannot walk a cell away. After each application the cell's evidence is cleared, so the next
correction is judged against the fuelling the engine now has: a loop, not a ramp.

Two refusals are absolute. A narrowband O2 sensor reports only rich or lean of stoichiometric
while publishing on the same channel as a wideband, so tuning on it would produce a table that
is confidently wrong everywhere the engine is not meant to run at stoich - autotuning will not
arm. And it needs the same write permission as any other edit.

**Autotuning never touches the ECU.** Corrections land in the loaded tune and show as ordinary
red/blue changed cells; the ECU changes only when you burn, through the same
write-verify-CRC-burn path as a hand edit.

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
cannot drift apart. It defaults to Celsius, and is chosen in App settings.

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
5. **Bounded when automatic.** Autotuning moves a cell by a small step at a time and never
   further from where it started than the session limit, refuses to run on a sensor that cannot
   measure what it needs, and still cannot reach the ECU without a burn.
6. **Confirmed when there is no burn.** A sensor calibration is saved by the ECU the moment it
   arrives. Sending one needs write mode as well, is confirmed first, and is checked against
   the checksum the ECU keeps of what it saved.

## License

GPLv3 - see [LICENSE](LICENSE). This matches the Speeduino firmware's own license.
