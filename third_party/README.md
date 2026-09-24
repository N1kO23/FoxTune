# Vendored packages

Copies of two Flutter plugins, patched so the Android build works with Gradle 9. Both call
`jcenter()` in their Android build scripts - a method Gradle 9 removed - and neither has a
release without it. `packages/foxtune_transport` depends on these copies by path.

| Package                 | Upstream                                                                          | Version | License                                                         |
| ----------------------- | --------------------------------------------------------------------------------- | ------- | --------------------------------------------------------------- |
| `flutter_libserialport` | [jpnurmi/flutter_libserialport](https://github.com/jpnurmi/flutter_libserialport) | 0.6.0   | MIT; the bundled libserialport is LGPL-3.0-or-later (`COPYING`) |
| `usb_serial`            | [altera2015/usbserial](https://github.com/altera2015/usbserial)                   | 0.5.2   | BSD-3-Clause                                                    |

Each is the pub.dev release as published, less `example/`, `doc/`, `test/` and build output.

## Patches

Only the Android build scripts differ from upstream. Both keep upstream's CRLF line endings, so a
diff against the release shows just these lines:

- **`flutter_libserialport/android/build.gradle`**: `jcenter()` becomes `mavenCentral()`, in both
  places. Everything it resolved is on Google's Maven or Maven Central.
- **`usb_serial/android/build.gradle`**: `jcenter()` becomes `mavenCentral()`, and the
  `buildscript` block is gone. That block only matters when the plugin is built on its own, and it
  would fetch AGP 4.1.0, whose dependencies partly lived on JCenter alone; the app supplies AGP
  instead. JitPack stays: it serves `com.github.felHR85:UsbSerial`. It also compiles against
  `flutter.compileSdkVersion` rather than a fixed 33: the AndroidX libraries Flutter's embedding
  brings in need 34 or later, and the release build refuses a library compiled against less.

## Still to do

The Android build warns that `flutter_libserialport` applies the Kotlin Gradle plugin itself, and
that a future Flutter will refuse to build such a plugin. The fix is to move it to AGP 9's built-in
Kotlin, per Flutter's
[guide for plugin authors](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors) -
best done alongside the Flutter bump that turns the template's `android.builtInKotlin=false` off.

## Updating

Dependabot does not see vendored packages, so check upstream by hand now and then.

- **Upstream releases the same fixes**: point `packages/foxtune_transport/pubspec.yaml` back at
  the pub.dev release and delete the copy here.
- **A newer upstream release before then**: replace the copy with it, apply the patches above
  again, and build the Android app to confirm.
