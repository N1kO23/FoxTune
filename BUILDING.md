# Building FoxTune

## Prerequisites

The Flutter SDK, which bundles Dart. FoxTune is developed against **Flutter 3.47 / Dart 3.13**.

```sh
# Linux, no package manager needed
curl -LO https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.4-stable.tar.xz
tar -xf flutter_linux_3.47.4-stable.tar.xz -C ~
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

## Android

> The Android build is pinned to **Gradle 8.14.5 / AGP 8.11.1**. Do not bump it without
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
`jcenter()` disappears at Gradle 9.0, which leaves the Gradle 8.14.x line. Flutter will print a
version warning; that is expected.

Ways out, in rough order of preference:

1. Upstream drops `jcenter()` - then remove the pin.
2. Vendor a patched copy of the plugin under `third_party/` and use a path dependency.
3. Replace `flutter_libserialport` with the pure-Dart `libserialport` package and ship the
   native library through the desktop build ourselves. That package has no Android module at
   all, so the problem disappears - at the cost of doing the desktop packaging by hand.

### Permissions

The release manifest (`android/app/src/main/AndroidManifest.xml`) declares:

| Declaration                   | Why                                                                |
| ----------------------------- | ------------------------------------------------------------------ |
| `android.permission.INTERNET` | TCP transport - a WiFi bridge, or the simulator on another machine |
| `android.hardware.usb.host`   | USB OTG enumeration; without it `listDevices()` returns nothing    |

`INTERNET` has to be declared explicitly. Flutter's template only puts it in the **debug** and
**profile** manifests, so a release APK built without it fails every socket with
`OS Error: Operation not permitted, errno = 1` - Android refuses `socket()` outright to a
process that does not hold the permission. It works in debug and breaks in release, which makes
it easy to miss.

Local network access needs nothing extra today: at `targetSdk` 36 it is implicitly granted by
`INTERNET`, and Google's guidance is _not_ to declare `ACCESS_LOCAL_NETWORK` yet. That changes
at `targetSdk` 37 (Android 17), where local network access is blocked by default and
`ACCESS_LOCAL_NETWORK` becomes a runtime permission that has to be requested. Revisit this when
the target SDK moves.

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

## Continuous integration

`.github/workflows/ci.yml` runs four jobs:

| Job             | What it proves                                                         |
| --------------- | ---------------------------------------------------------------------- |
| `core`          | The pure-Dart packages analyze, format and test with a bare Dart SDK   |
| `flutter`       | The transport package and app analyze, and the app's widget tests pass |
| `build-linux`   | The desktop app links, and publishes a `.tar.gz` artifact              |
| `build-android` | The APK compiles, is signed, and publishes an artifact                 |

The `core` job is the fast signal and should stay that way: it needs no device, display or
emulator.

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

**No serial ports listed on Linux** - your user is probably not in the `dialout` group:

```sh
sudo usermod -aG dialout "$USER"   # log out and back in
```

**`OS Error: Operation not permitted, errno = 1` when connecting to a network ECU** - the
Android build is missing the `INTERNET` permission. See the Android permissions section; note
that debug builds have it and release builds do not unless it is declared in the main manifest.

**`Could not find method jcenter()`** - see the Android section above; the Gradle pin was
probably bumped.
