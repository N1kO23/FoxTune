# Building FoxTune

## Prerequisites

The Flutter SDK, which bundles Dart. FoxTune is developed against **Flutter 3.47 / Dart 3.13**.

```sh
# Linux, no package manager needed
curl -LO https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.5-stable.tar.xz
tar -xf flutter_linux_3.47.5-stable.tar.xz -C ~
export PATH="$HOME/flutter/bin:$PATH"   # add this to your shell profile
flutter doctor          # must show the Linux toolchain as ✓ before building
```

Per-platform build dependencies:

| Target  | Needs                                                                                  |
| ------- | -------------------------------------------------------------------------------------- |
| Linux   | `ninja`, `cmake`, **`clang` and `clang++` on `PATH`**, `pkg-config`, GTK 3 dev headers |
| Android | Android SDK + JDK 17 (`flutter doctor --android-licenses`)                             |
| Windows | Visual Studio with the Desktop C++ workload                                            |
| macOS   | Xcode                                                                                  |

On Gentoo that set is `dev-build/ninja dev-build/cmake llvm-core/clang dev-util/pkgconf
x11-libs/gtk+:3` - note GTK **3**, since `gui-libs/gtk` is GTK 4 and Flutter's Linux embedder
still uses GTK 3. On Debian/Ubuntu: `ninja-build cmake clang pkg-config libgtk-3-dev`.

### Clang has to be on PATH, and on Gentoo it is not by default

Flutter's Linux build hardcodes `CC=clang` and `CXX=clang++`. Gentoo slots LLVM under
`/usr/lib/llvm/<slot>/bin` and does **not** create `/usr/bin/clang`, so installing
`llvm-core/clang` is not enough on its own - the slot's bin directory has to be on `PATH`:

```sh
export PATH="/usr/lib/llvm/21/bin:$PATH"    # check `ls -d /usr/lib/llvm/*/bin` for your slot
```

Without it the build fails with a message Flutter swallows into `Error: Build process failed`;
`flutter build linux` shows the real cause:

```
CMake Error ... Could not find the compiler specified in the environment variable CXX: clang++.
CMake Error: CMAKE_CXX_COMPILER not set, after EnableLanguage
```

`flutter doctor` diagnoses this correctly, so check it first when a Linux build fails:

```
[✗] Linux toolchain - develop for Linux desktop
    ✗ clang++ is required for Linux development.
```

What makes it confusing is that an unrelated toolchain can mask the problem. A Swift install
via swiftly, for example, puts its own `clang` on `PATH` - so the same checkout builds in a
shell where swiftly is initialised and fails in one where it is not, and `flutter doctor`
passes in the first. If a build works in one terminal and not another, compare
`command -v clang++` between them.

### File dialogs need the desktop portal

On Linux, opening and saving files goes through the XDG desktop portal (its `FileChooser`
interface, over D-Bus). The file picker has no fallback to zenity or kdialog, so without a portal
running there is no file dialog at all: saving a tune, importing a table or choosing a definition
fails with an error naming `org.freedesktop.portal.Desktop`.

Full desktops such as Plasma and GNOME run a portal already. A bare window manager may not:
install `xdg-desktop-portal` together with the backend for your desktop - `xdg-desktop-portal-kde`
on Plasma, `xdg-desktop-portal-gnome` on GNOME, `xdg-desktop-portal-gtk` anywhere else.

## Where to run things

This matters more than it should, and is the most common source of confusion:

**Dart commands run from the repository root. Flutter commands run from the package directory.**

The root is a Dart _workspace_ holding the three pure-Dart packages. It is not a Flutter app,
so `flutter build linux` from the root fails with `Target file "lib/main.dart" not found` -
that is the working directory being wrong, not a broken build.

```sh
# Core packages - from the repository root
dart pub get
./tool/test.sh                 # tests for every pure-Dart workspace member
dart analyze
dart format .

# The app - from its own directory
cd app/foxtune_app
flutter pub get
flutter test
flutter analyze
flutter run -d linux
flutter build linux            # output: build/linux/x64/release/bundle/

# The transport package - likewise
cd packages/foxtune_transport
flutter pub get && flutter test
```

`tool/test.sh` deliberately covers only the workspace members. `foxtune_transport` and the app
depend on the Flutter SDK, so `dart test` cannot load their tests; run those with `flutter test`
from their own directories.

## The desktop window frame

On Linux and Windows the app draws its own title bar: the top app bar of each screen doubles as
it (`WindowAppBar`, in `lib/src/window/`), and `window_manager` hides the native one at startup.
New full-window screens should use `WindowAppBar` rather than `AppBar`, or they will have no
way to move or close the window. macOS and Android keep their native frame.

The Linux runner still creates a GTK header bar on every session, only for it to be hidden. That
is deliberate: a window with a GTK titlebar stays client-side decorated, so GTK keeps drawing the
shadow and the resize edges, and tells KWin not to add a title bar of its own. Without one,
`window_manager` falls back to an undecorated window, which has neither.

### The icon on Wayland

A Wayland session shows a generic icon for FoxTune in the task manager until its desktop entry is
installed. Wayland compositors ignore the icon a window sets and instead look up the `.desktop`
entry named after the application ID (`com.foxtune.foxtune_app`). X11 needs nothing: the runner
sets the icon on the window itself. To install the entry and icons for your user, pointing at a
build:

```sh
flutter build linux                 # from app/foxtune_app
../../tool/install-linux-desktop.sh # or pass another bundle directory
```

The release tarball carries the same script: run `./install-linux-desktop.sh` from the `foxtune/`
directory it unpacks to.

Start FoxTune from that entry: the application menu, KRunner or a pinned task. KDE's System
Monitor names an application after whatever launched it, so a FoxTune started by double-clicking
the `foxtune` executable shows up there as the executable's path, and one started from a terminal
shows up under the terminal.

The AppImage needs its entry installed too, for example by AppImageLauncher. That renames the
entry, so Plasma falls back to the entry's `StartupWMClass` to match FoxTune's window to it -
which is why `StartupWMClass` has to stay equal to the application ID.

The brand artwork, and where each platform's icons come from, is described in
[branding/README.md](branding/README.md).

## Developing without an ECU

You do not need a Speeduino to work on almost any of this. The protocol package ships a
simulator that speaks the real wire protocol over TCP and drives a plausible running engine:

```sh
cd packages/foxtune_tune
dart run bin/fake_ecu.dart --msq /path/to/your-tune.msq
```

Then start the app and choose **Network ECU** → `127.0.0.1:2000`. Gauges move, the live table
cursor travels across cells, and warning thresholds are actually reached.

| Flag         | Effect                                          |
| ------------ | ----------------------------------------------- |
| `--msq PATH` | Seed the pages from a real tune                 |
| `--port N`   | Listen on a different port                      |
| `--ini PATH` | Use a different ECU definition                  |
| `--static`   | Serve a fixed block instead of a running engine |

**Pass a real tune.** Without one the simulator serves empty pages, which is not merely
unrealistic - it is wrong in a way that looks like an app bug. Several realtime channels scale
by an _expression_ rather than a constant: `fuelLoad`, the VE table's load axis, scales by
`{ fuelLoadFeedBack }`, which resolves through a computed channel to the `algorithm`
configuration constant. With no tune there is no `algorithm`, so the channel cannot be written
and keeps whatever filler was in the block - a nonsense load that pins the live table cursor to
the top row regardless of what the engine is doing. The simulator prints a warning naming any
channel it could not scale.

A base tune from a different firmware build is fine: values are matched by name, so whatever
applies is loaded and the rest is reported.

The one layer this cannot exercise is the desktop serial driver itself: libserialport rejects
pseudo-terminals, so a `socat` loopback is not a usable stand-in for a real port. That layer
needs real hardware or a tty0tty-style kernel module.

### A simulated rusEFI

Give `fake_ecu` a rusEFI definition and it serves a rusEFI - rusEFI's commands, page addressing
and live-data layout - on port 29001:

```sh
cd packages/foxtune_tune
dart run bin/fake_ecu.dart --ini ../foxtune_ini/test/fixtures/rusefi_uaefi.ini
```

Connect with **Network ECU** → `127.0.0.1:29001`. FoxTune will look for the definition on
rusefi.com; for the vendored fixture it finds it, and for any other it asks you for the file.

### rusEFI's own simulator

rusEFI builds its real firmware for a PC too, answering on TCP port 29001. It is not in rusEFI's
releases, so it is built from source. This worked on Gentoo against rusEFI master of 2026-09-21:

```sh
git clone --depth 1 https://github.com/rusefi/rusefi.git
cd rusefi
git submodule update --init --depth 1 \
    firmware/ChibiOS firmware/ChibiOS-Contrib firmware/libfirmware \
    firmware/ext/uzlib firmware/ext/lua firmware/controllers/lua/luaaa \
    firmware/ext/magic_enum firmware/controllers/can/wideband_firmware \
    firmware/ext/openblt
cd simulator
make -j"$(nproc)"
./build/rusefi_simulator        # no argument: runs until stopped
```

What the build needs beyond `make`:

- **A GCC that builds 32-bit code.** The simulator compiles with `-m32`. Gentoo's default
  amd64 profiles are multilib, so this works out of the box; elsewhere it is usually a
  `gcc-multilib`/`g++-multilib` package. `echo 'int main(){}' | g++ -m32 -x c++ - -o /dev/null`
  says whether you have it.
- **A JDK.** The build runs Gradle to generate code from rusEFI's configuration.
- **mtools** (`sys-fs/mtools`), plus `zip`, `7z`, `xxd` and `mkfs.fat`. The build packs the
  definition into the image an ECU shows as a USB drive, even for the simulator, and fails with
  `mcopy: command not found` without mtools. Building mtools from GNU's source into a private
  prefix and putting its `bin` on `PATH` for the `make` is enough if you would rather not
  install it.

Then connect FoxTune with **Network ECU** → `127.0.0.1:29001`. The simulator runs the
f407-discovery configuration; if rusEFI has published the definition for that build, FoxTune
downloads it, and otherwise asks for the file - the build writes it to
`firmware/tunerstudio/generated/rusefi_f407-discovery.ini`.

The simulator answers every request about 40 ms late, whoever sends it, so live data from it
runs at about 7 samples a second. A board over USB does not have this limit.

## Android

> The Android build is pinned to **Gradle 8.14.5 / AGP 8.13.2**. Do not bump it without
> reading this.

Gradle 9.0 removed the `jcenter()` repository method. `flutter_libserialport` - still at 0.6.0,
last released August 2025 - calls `jcenter()` in its `android/build.gradle`, so any Gradle 9
build fails while evaluating that subproject:

```
* Where: .../flutter_libserialport-0.6.0/android/build.gradle line: 8
> Could not find method jcenter() for arguments []
```

The plugin is only used on desktop; Android serial goes through `usb_serial`. But Flutter
includes a plugin's Android module whenever the plugin declares Android support, and there is
no supported way to exclude one per platform - so the whole app build has to stay on Gradle 8
until upstream drops jcenter.

The usable window is narrow. Flutter 3.47 hard-errors below Gradle 8.14.0 and AGP 8.11.1, and
`jcenter()` disappears at Gradle 9.0, which leaves the Gradle 8.14.x line - and, since AGP 9
needs Gradle 9, the AGP 8.x line. Flutter will print a version warning; that is expected.

Ways out, in rough order of preference:

1. Upstream drops `jcenter()` - then remove the pin.
2. Vendor a patched copy of the plugin under `third_party/` and use a path dependency.
3. Replace `flutter_libserialport` with the pure-Dart `libserialport` package and ship the
   native library through the desktop build ourselves. That package has no Android module at
   all, so the problem disappears - at the cost of doing the desktop packaging by hand.

### Permissions

The release manifest (`android/app/src/main/AndroidManifest.xml`) declares:

| Declaration                   | Why                                                                          |
| ----------------------------- | ---------------------------------------------------------------------------- |
| `android.permission.INTERNET` | TCP transport - a WiFi bridge, or the simulator on another machine           |
| `android.hardware.usb.host`   | Declares USB host (OTG) use; `required="false"` keeps TCP-only phones listed |
| `USB_DEVICE_ATTACHED` filter  | Plugging in a known board offers to open FoxTune (see below)                 |

`INTERNET` has to be declared explicitly. Flutter's template only puts it in the **debug** and
**profile** manifests, so a release APK built without it fails every socket with
`OS Error: Operation not permitted, errno = 1` - Android refuses `socket()` outright to a
process that does not hold the permission. It works in debug and breaks in release, which makes
it easy to miss.

`usb.host` is a declaration only. Permission to talk to a particular device is separate: Android
asks the first time FoxTune opens it, or grants it up front when FoxTune was launched from the
plug-in prompt.

**Plugging in.** `MainActivity` registers for `USB_DEVICE_ATTACHED`, filtered by
`res/xml/device_filter.xml`, so plugging a Speeduino in asks "Open FoxTune when this is
connected?". Ticking **always** makes Android remember the USB permission, so connecting stops
prompting. The filter lists vendor IDs, in decimal, and must match `EcuPort.knownEcuVendorIds`
in `foxtune_transport` - a test fails if the two drift apart.

Local network access needs nothing extra today: at `targetSdk` 36 it is implicitly granted by
`INTERNET`, and Google's guidance is _not_ to declare `ACCESS_LOCAL_NETWORK` yet. That changes
at `targetSdk` 37 (Android 17), where local network access is blocked by default and
`ACCESS_LOCAL_NETWORK` becomes a runtime permission that has to be requested. Revisit this when
the target SDK moves.

### Testing on a phone

CI builds the APK, but nothing in CI can plug a cable in. Before trusting a build in a car,
go through this with the phone and a Speeduino - the bench ECU is fine, engine off:

1. **Plug in.** Android offers to open FoxTune. Tick **always**; unplug and replug - FoxTune
   opens with no permission prompt, and the board is at the top of the list.
2. **Deny once.** Clear FoxTune's defaults (Settings → Apps → FoxTune → Open by default),
   replug, connect, tap **Deny**. The message says permission was denied - not a raw
   exception - and connecting again asks again.
3. **Connect over OTG.** Gauges move. Leave it for longer than the screen timeout; the screen
   stays on. Disconnect; the screen times out normally again.
4. **Pull the cable** with an unburned edit made (change one table cell). Within about a second
   the app says **Connection lost**, and offers to save the edit as a `.msq`.
5. **Files.** Save a tune to Downloads, then load it back. Export a table and re-import it.
6. **Logs.** Record for ten seconds, stop, tap **Save log…** in the message, and open the `.msl`
   off the phone. The folder button next to **Record** lists earlier logs.

Anything that behaves differently goes in an issue with the phone model and Android version:
USB host support varies more between manufacturers than anywhere else on Android.

## Release signing

Release signing is driven entirely by the environment, so no keystore is ever committed:

| Variable                    | Set by                                       |
| --------------------------- | -------------------------------------------- |
| `ANDROID_KEYSTORE_PATH`     | CI, after decoding `ANDROID_KEYSTORE_BASE64` |
| `ANDROID_KEYSTORE_PASSWORD` | secret                                       |
| `ANDROID_KEY_ALIAS`         | secret                                       |
| `ANDROID_KEY_PASSWORD`      | secret                                       |

When `ANDROID_KEYSTORE_PATH` is unset - every local build, and any fork without the secrets -
the release build falls back to the debug key so `flutter build apk --release` still produces
an installable APK. It is just not distributable.

The signing block lives in `android/app/build.gradle.kts`, not the root `build.gradle.kts`.
That is not cosmetic: the Android Gradle plugin is applied to the `:app` module, so `android { }`
in the root project is an unresolved reference and fails the build script compile with
`Unresolved reference: signingConfigs`.

To sign locally, point the same variables at your own keystore:

```sh
export ANDROID_KEYSTORE_PATH=/path/to/foxtune.jks
export ANDROID_KEYSTORE_PASSWORD=... ANDROID_KEY_ALIAS=... ANDROID_KEY_PASSWORD=...
flutter build apk --release
```

## Releasing

A release is a tag. Its version comes from `app/foxtune_app/pubspec.yaml`, where
`version: 1.2.0+7` means version 1.2.0, build number 7:

```sh
# Set the version in app/foxtune_app/pubspec.yaml and commit it, then:
./tool/check-release-version.sh v1.2.0   # the same check CI makes
git tag v1.2.0
git push origin v1.2.0
```

The tag runs all of CI, tests included, and then drafts a GitHub release carrying the Linux
tarball and AppImage, the Windows zip, the signed APK and a `SHA256SUMS` file. Nothing is public
until you look the draft over and publish it from the releases page.

Before anything is built, the tag is checked against the pubspec:

- **The tag must match the version:** `v1.2.0` for `version: 1.2.0+7`.
- **The build number must be higher than the last release's.** It is Android's version code, and
  Android will not install a build over one with a higher code. Once a release is installed, a
  lower number cannot follow it.

A release also refuses to build without the signing keystore secrets: an APK signed with the
debug key could never be updated by a properly signed one.

To redo a failed release, delete the tag and any draft it left, then tag again:

```sh
git push --delete origin v1.2.0 && git tag -d v1.2.0
```

## Measuring dashboard performance

Judge smoothness in a profile or release build, never in a plain `flutter run`: debug builds
run Dart unoptimised, and a dashboard that is smooth in release can stutter there.

To put numbers on it, a benchmark draws a real saved layout (4 time graphs, 11 gauges and
14 lamps) from a synthetic 30 Hz feed, with the whole connected shell up, and records frame
timings in profile mode on the desktop:

```sh
cd app/foxtune_app
flutter drive --profile -d linux \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/dashboard_perf_test.dart
```

It opens a window for about 40 seconds and writes the summary to
`build/integration_response_data.json`: build (UI thread) and raster times, average and
percentiles, once with the dashboard showing and once with it hidden behind the Tables tab. At
30 Hz only about every other frame carries a new sample, so the 90th percentile is the figure to
watch. Keep it well under the 16 ms a 60 Hz frame allows.

Two rules keep it low, and the benchmark shows it when either is broken:

- **A widget showing live data watches it with `watchWhileVisible`**, not `ref.watch`. The shell
  keeps every tab alive, so a plain watch rebuilds hidden screens 30 times a second.
- **A dashboard gauge watches only what it shows** (`realtimeProvider.select`), so a lamp that
  holds its state and the page around it are not rebuilt per sample.

## Dependencies

Every `pubspec.lock` is committed - the workspace root's, the app's and the transport package's -
and CI resolves with `--enforce-lockfile`. It builds exactly the versions they pin, and fails if a
pubspec asks for something they do not, so updating is always a change you commit:

```sh
dart pub upgrade                                       # from the root: the core packages
(cd app/foxtune_app && flutter pub upgrade)
(cd packages/foxtune_transport && flutter pub upgrade)
```

The app and the transport package resolve the core packages' dependencies too. After changing a
core package's pubspec, run `flutter pub get` in both and commit their lockfiles along with the
root's; CI points out one that was missed.

Dependabot proposes updates weekly as pull requests (`.github/dependabot.yml`): minor and patch
updates grouped, each major version on its own, since that can need code changes. It leaves the
Android Gradle files alone; see the Android section for why. It also keeps the workflow's actions
current, which are pinned to commits rather than tags: a tag can be moved to other code, and the
Android job runs with the release signing key.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main`, every pull request, and every release
tag:

| Job             | What it proves                                                                             |
| --------------- | ------------------------------------------------------------------------------------------ |
| `version`       | Names the build; for a release tag, first checks the tag against the app's version         |
| `core`          | The pure-Dart packages analyze, format and test with a bare Dart SDK                       |
| `flutter`       | The transport package and app analyze and are formatted, and their tests pass              |
| `build-linux`   | The desktop app links and starts on glibc 2.35+, and publishes a `.tar.gz` and an AppImage |
| `build-windows` | The Windows app links, and publishes a `.zip` that carries the MSVC runtime                |
| `build-android` | The APK compiles, is signed, and publishes an artifact                                     |
| `release`       | Release tags only: drafts a GitHub release from the artifacts, with `SHA256SUMS`           |

The `core` job is the fast signal and should stay that way: it needs no device, display or
emulator. It runs on the Dart SDK that the pinned Flutter ships (`DART_VERSION` in the
workflow), since the formatter's output changes between SDK releases; bump the two together.

The Linux build runs on a pinned Ubuntu release rather than `ubuntu-latest`, because the build
machine's glibc sets the oldest distribution the bundle will start on. `tool/check-linux-glibc.sh`
fails the job if anything in the bundle needs a glibc newer than 2.35, Ubuntu 22.04's. The same
script explains a locally built AppImage that will not start elsewhere: built on a rolling
distribution, libserialport alone needs that distribution's glibc.

```sh
./tool/check-linux-glibc.sh                 # checks the release bundle against 2.35
```

## Troubleshooting

**`Target file "lib/main.dart" not found`** - you ran a Flutter command from the repository
root. `cd app/foxtune_app` first.

**`dart test` fails to load a `flutter_test` import** - you pointed it at `foxtune_transport`
or the app. Use `flutter test` from that package's directory.

**`Error: Build process failed` from `flutter run -d linux`** - `flutter run` hides the
compiler output. Run `flutter build linux` instead to see the real error. The usual cause is
`clang++` not being on `PATH`; see the clang note above.

**`SerialPortError: Invalid argument, errno = 22`** - libserialport was handed something that
is not a real serial device, typically a `socat` pseudo-terminal.

**An error naming `org.freedesktop.portal.Desktop` when opening or saving a file** - no desktop
portal is running. See "File dialogs need the desktop portal" above.

**No serial ports listed on Linux** - your user is probably not in the `dialout` group:

```sh
sudo usermod -aG dialout "$USER"   # log out and back in
```

**`OS Error: Operation not permitted, errno = 1` when connecting to a network ECU** - the
Android build is missing the `INTERNET` permission. See the Android permissions section; note
that debug builds have it and release builds do not unless it is declared in the main manifest.

**`Could not find method jcenter()`** - see the Android section above; the Gradle pin was
probably bumped.
