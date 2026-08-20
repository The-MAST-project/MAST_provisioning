---
decided: 2026-08-20
status: accepted
issue: MAST_provisioning#119
areas:
  - operator tooling
---

# Glyphs are filled outlines, because ClearType has no meaning offscreen

**Why:** the hostname on the unit background had stair-stepped edges. The first explanation offered was scaling, and it was wrong in an instructive way.

mast05's panel is 1920x1200; the renderer is hard-coded 1920x1080. `WallpaperStyle 10` (Fill) covers by upscaling 111% and cropping 213 px of width, so there was a real resample sitting on the image. Re-rendering at the panel's native size removed it and the text was still ragged. That is what isolated the cause: the roughness was in the PNG, not in how Windows displayed it.

`DrawString` under `TextRenderingHint.ClearTypeGridFit` is subpixel antialiasing -- it spreads coverage across a display's R, G and B subpixels. The target here is an offscreen `Bitmap` with no subpixel geometry to filter against, and the output degrades toward near-binary edges. The size dependence falls out of that: on the 22-40 px lines a step is about a pixel and reads as ordinary text, while on a 128 px glyph the same step is plainly visible as a ragged diagonal.

**What:**

- Every line is built with `GraphicsPath.AddString` and drawn with `FillPath`, under `SmoothingMode.HighQuality` and `PixelOffsetMode.HighQuality`. Filling an outline antialiases against real geometric coverage, so it is smooth at any size.
- `TextRenderingHint` stays set, at `AntiAliasGridFit`. It no longer governs any glyph the render draws, but `MeasureString` still uses it for layout, and measuring under a hint the render does not use would size the text block against the wrong metrics.
- Identity text moves from `#E6EDF3` to `#B1BAC4`. Against `#0B0E14` a near-white is close to maximum contrast, and at 128 px it reads as glare on the enclosure monitor rather than as a label. Two notches down the same ramp, judged on that monitor rather than on a screenshot.
- `RendererVersion` 3 -> 4, which is what carries this to units that already hold an image.

**Colour fringing was the symptom nobody had named.** ClearType encodes its subpixel weighting as actual colour, so every deployed background carried orange and blue fringes on the small text, baked into the file. It had been read as "the small text looks fine", and at 22 px it is subtle. It is wrong regardless: that colour is only correct for a display whose subpixel order matches the assumption, and a wallpaper is rescaled and recomposited before it reaches one. Outline fill emits no colour, so the small lines came out cleaner too -- the opposite of the risk that argued for treating them separately.

**One code path, not a size threshold.** The obvious shape was to keep `DrawString` for the small lines and use outlines only for the hostname, since only the hostname was complained about. Rejected once the magnified comparison showed the small lines were also carrying fringing: a by-size branch would have preserved a defect in the branch nobody was looking at, and left two rasterization paths to reason about.

**Rejected:**

- **Rendering at a much higher resolution and letting Windows downscale.** It was the first instinct, and it treats a rasterizer bug as a sampling problem -- the edges are jagged in the source, so a 4K render is jagged too, merely smaller. Downscaling would have partly masked it and made the real cause harder to find.
- **`AntiAliasGridFit` with `DrawString`.** Most of the improvement for a one-word change, and it keeps hinting at small sizes. Not taken because it is still glyph rasterization tuned for a display, and `FillPath` was visibly better on the 128 px curves, which is the case that prompted this.

**Unsettled:**

- **The render size still does not follow the display.** 1920x1080 remains hard-coded while the enclosure display changes and NoMachine sessions are sized arbitrarily, so some rescaling is normal. The growth-seam note in the renderer describes moving to a per-user image regenerated at logon; catching a mid-session NoMachine resize needs more than that -- a resident watcher on `SystemEvents.DisplaySettingsChanged` -- which would be the first thing this provider leaves running in a session. Deliberately not decided here: sharp text under moderate rescaling may be good enough, and that is now judgeable on its own.
- **`#B1BAC4` was judged on one monitor**, the provisioning display, not on an enclosure unit in the dark.
- **Segoe UI is assumed present.** True of every Windows unit, and unchanged by this, but the outline path fails differently from `DrawString` if it ever is not.
