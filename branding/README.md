# FoxTune brand assets

Colours: pink `#FF2E6E`, black `#000000`, off-white `#FAFAFA`, white `#FFFFFF`.
Wordmark typeface: Montserrat (Bold "Fox", Regular "Tune", Medium tagline). In every SVG and PNG
here the text is already converted to outlines, so no font needs to be installed.

"dark" files are for dark backgrounds, "light" files for light backgrounds. All logos have
transparent backgrounds.

This folder holds the master artwork. What each platform build actually uses is copied or
rendered from it into the app - see [Where it is used](#where-it-is-used).

## What is here

- `logo/` - `svg/` scales to any size; `png/` holds large renders.
  - horizontal: emblem + wordmark + tagline side by side
  - stacked: emblem above wordmark + tagline
  - emblem: the fox girl badge on its own
  - wordmark: "FoxTune" text only
  - emblem-mono-black / -white: single-colour emblem for embossing, watermarks, etc.
- `icon/` - the app icon as a 1024 px PNG and SVG, rounded-square and round versions. Its lines
  are slightly heavier than the master logo's so it stays readable at small sizes.
- `splash/` - `splash-android12-*.png` is the 1152 x 1152 Android 12+ splash icon (fits the
  768 px circle); `splash-logo-*.png` is the stacked logo for older Android and loading screens.
  Not wired up yet.
- `store/` - the Google Play listing icon (full square; Play rounds the corners) and the
  1024 x 500 feature graphic.

## Where it is used

All paths below are under `app/foxtune_app/`.

| Where                | Files                                                                    | From                                                                                           |
| -------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| Android launcher     | `android/app/src/main/res/mipmap-*`, `values/ic_launcher_background.xml` | The brand bundle's drop-in `android/res/`: legacy, round, adaptive and Android 13 themed icons |
| Linux                | `linux/icons/hicolor/*/apps/foxtune.*`                                   | The brand bundle's pre-rendered 16-512 px set                                                  |
| Windows              | `windows/runner/resources/app_icon.ico`                                  | The Linux 16-256 px renders, one layer each; the 256 px layer is stored as PNG                 |
| macOS                | `macos/Runner/Assets.xcassets/AppIcon.appiconset/`                       | The Linux renders, and `icon/foxtune-icon-1024.png`                                            |
| In the app (app bar) | `assets/branding/`                                                       | Rendered from the SVGs, see below                                                              |
| In the app (colours) | `lib/src/branding/brand_theme.dart`                                      | The pink as the accent, on neutral surfaces                                                    |

The Linux set is PNG only, with no `scalable/` SVG. KDE draws icons with Qt, whose SVG renderer
supports only SVG Tiny: it skips nested `<svg>` elements and ignores clip paths, and every SVG
here is built from both. As a desktop icon, KDE would draw it as a plain black square or with
the lines in the wrong colours. Browsers and librsvg draw these SVGs correctly.

On Linux the build copies the icons and `linux/com.foxtune.foxtune_app.desktop` into the bundle.
X11 gets the window icon from there directly. Wayland only shows it once the desktop entry is
installed: `tool/install-linux-desktop.sh` does that for the current user.

The app bar shows the app icon and the wordmark rather than the bare emblem, whose line art
does not survive being drawn 36 px tall. Both are rendered at exactly their on-screen size, so
they stay sharp instead of being scaled down at runtime. To re-render them, from the repository
root:

```sh
out=app/foxtune_app/assets/branding
for scale in 1 2 3; do
  dir=$out; [ $scale -gt 1 ] && dir=$out/$scale.0x
  rsvg-convert -w $((36 * scale)) -h $((36 * scale)) branding/icon/foxtune-icon.svg -o $dir/foxtune-icon.png
  for v in dark light; do
    rsvg-convert -h $((20 * scale)) branding/logo/svg/foxtune-wordmark-$v.svg -o $dir/foxtune-wordmark-$v.png
  done
done
```
