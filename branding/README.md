# FoxTune brand assets

Colours: pink `#FF2E6E`, black `#000000`, off-white `#FAFAFA`, white `#FFFFFF`.
Wordmark typeface: Chakra Petch - "Fox" Bold Italic in pink, "Tune" Medium Italic, the tagline
SemiBold Italic. In every SVG and PNG here the text is already converted to outlines, so no font
needs to be installed.

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
  768 px circle); `splash-logo-*.png` is the stacked logo for older Android and loading screens,
  rendered from `logo/svg/` (see the end of this file). Not wired up yet.
- `store/` - the Google Play listing icon (full square; Play rounds the corners) and the
  1024 x 500 feature graphic.

## Where it is used

All paths below are under `app/foxtune_app/`.

| Where                  | Files                                                                    | From                                                                                           |
| ---------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| Android launcher       | `android/app/src/main/res/mipmap-*`, `values/ic_launcher_background.xml` | The brand bundle's drop-in `android/res/`: legacy, round, adaptive and Android 13 themed icons |
| Linux                  | `linux/icons/hicolor/*/apps/foxtune.*`                                   | The brand bundle's pre-rendered 16-512 px set, and a flattened SVG (see below)                 |
| Windows                | `windows/runner/resources/app_icon.ico`                                  | The Linux 16-256 px renders, one layer each; the 256 px layer is stored as PNG                 |
| macOS                  | `macos/Runner/Assets.xcassets/AppIcon.appiconset/`                       | The Linux renders, and `icon/foxtune-icon-1024.png`                                            |
| In the app (app bar)   | `assets/branding/foxtune-icon.svg`, `foxtune-wordmark-*.svg`             | The flattened Linux icon, and the wordmark SVGs as they are - see below                        |
| In the app (wallpaper) | `assets/branding/foxtune-emblem-mono.svg`                                | `logo/svg/foxtune-emblem-mono-black.svg`, flattened - see below                                |
| In the app (colours)   | `lib/src/branding/brand_theme.dart`                                      | The pink as the accent, on neutral surfaces                                                    |

KDE draws icons with Qt, whose SVG renderer supports only SVG Tiny: it skips nested `<svg>`
elements and ignores clip paths, and every SVG here is built from both. As a desktop icon, KDE
draws `icon/foxtune-icon.svg` as a plain black square, or with every line pink once the nesting
is removed (checked with Qt 6.11). Browsers and librsvg draw these SVGs correctly. So the Linux
set's `scalable/apps/foxtune.svg` is a flattened copy: plain filled paths, with the clip paths
already cut into their outlines. It is made with [picosvg](https://github.com/googlefonts/picosvg);
to regenerate it after changing the icon, from the repository root:

```sh
pipx run picosvg --output_file app/foxtune_app/linux/icons/hicolor/scalable/apps/foxtune.svg \
  branding/icon/foxtune-icon.svg
```

Check the result in something that draws with Qt, such as Gwenview, before committing it.

On Linux the build copies the icons and `linux/com.foxtune.foxtune_app.desktop` into the bundle.
X11 gets the window icon from there directly. Wayland only shows it once the desktop entry is
installed: `tool/install-linux-desktop.sh` does that for the current user, and AppImageLauncher
does it for the AppImage.

The app bar shows the app icon and the wordmark rather than the bare emblem, whose line art
does not survive being drawn 36 px tall. The default wallpaper draws the single-colour emblem,
in the theme's own text colour.

The app draws all of these from SVGs, with flutter_svg, so they are sharp at any size and pixel
density - where a PNG is sharp only at the densities it was rendered for. flutter_svg shares
Qt's blind spot: it skips nested `<svg>` elements, and everything in them, without a word. So
the app's copies are flattened too: the icon is the flattened Linux one, the emblem is flattened
the same way, and the wordmarks, which nest nothing, are copied as they are. picosvg leaves an
empty `<defs/>` behind, which flutter_svg complains about on every load, so that is taken out.
The app's `test/branding_assets_test.dart` fails for any bundled SVG that still nests, or draws
nothing. To update them, from the repository root:

```sh
out=app/foxtune_app/assets/branding
cp app/foxtune_app/linux/icons/hicolor/scalable/apps/foxtune.svg $out/foxtune-icon.svg
cp branding/logo/svg/foxtune-wordmark-dark.svg branding/logo/svg/foxtune-wordmark-light.svg $out/
pipx run picosvg --output_file $out/foxtune-emblem-mono.svg \
  branding/logo/svg/foxtune-emblem-mono-black.svg
sed -i '/^\s*<defs\/>\s*$/d' $out/foxtune-icon.svg $out/foxtune-emblem-mono.svg
```

The splash logos are the stacked logo centred on a transparent 768 x 1024 canvas. Re-render them
whenever the stacked logo changes, from the repository root:

```sh
for v in dark light; do
  rsvg-convert -a -w 768 -h 1024 branding/logo/svg/foxtune-stacked-$v.svg |
    magick - -background none -gravity center -extent 768x1024 branding/splash/splash-logo-$v.png
done
```
