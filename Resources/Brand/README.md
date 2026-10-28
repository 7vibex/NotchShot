# NotchShot app icon

The coral capture buddy replaces the previous camera-eye mascot. The screen has a small top notch, two eyes and a smile; the menu-bar template keeps the same silhouette and face as transparent cutouts.

## Assets and consumers

- `AppIconArtwork.png`: original opaque square artwork, generated with the built-in imagegen tool. Keep this source independent of the macOS mask.
- `../AppIcon.png`: packaged 1024 px preview with transparent margins and a continuous-corner ivory tile.
- `../AppIcon.icns`: all ten standard macOS icon representations, 16–1024 px. Used by Finder, the Dock, system permission dialogs and other bundle-icon consumers through `CFBundleIconFile`.
- `Sources/NotchShotKit/UI/NotchShotLogo.swift`: monochrome companion for the menu bar, menu header and onboarding. AppKit supplies the menu-bar tint.

From the repository root, regenerate without a network request:

```sh
./Scripts/make_app_icon.sh
./Scripts/build_app.sh
```

The renderer applies a consistent 824 px tile inside a 1024 px canvas and generates each icon size from the source artwork. The bundle script copies the committed ICNS before signing. Regeneration does not call imagegen.

## Generation prompt

Built-in imagegen mode; initial generation requested transparency.

```text
Use case: logo-brand.
Asset type: final production macOS app icon for NotchShot, a Mac screenshot and screen-recording utility that lives in the display notch.
Primary request: Design a beautiful, genuinely cute, memorable new app icon. A single small friendly coral-red screen character with a tiny unmistakable dark MacBook-style notch cut into the middle of its top edge. Its softly rounded rectangular body is the capture/screen shape itself. Two small dark oval eyes, a tiny gentle curved smile, very subtle rosy cheeks. Simple, lovely, premium, calm personality. One small warm-white four-point camera flash at its upper right, detached from the character. No limbs or other characters.
Style/medium: meticulously art-directed soft 3D clay and satin ceramic, iconic simple geometry, smooth bevels, controlled studio highlights. Premium native Mac utility icon, charming and polished, not a toy illustration.
Composition/framing: one centered straight-on icon, square 1024x1024 canvas. Warm ivory macOS continuous-corner squircle tile occupying exactly about 82 percent of canvas, centered with generous fully transparent outer margins on all four sides (roughly 9 percent each). Coral character is large and centered within the tile, takes 70 percent of tile width, slight depth at its bottom edge, face clearly visible. All elements and soft contact shadow contained within the ivory tile. Character's top notch is a real visible inward U-shaped bite in its top edge, about one fifth of the character width; its interior is dark charcoal. Use strong silhouette and balanced negative space. The shape reads at 32 pixels.
Lighting/mood: soft upper-left light, soft warm depth, subtle ivory base shading, joyful and understated.
Color palette: porcelain ivory base, rich warm coral-red character, near-black eyes and smile. Restrained and cohesive.
Constraints: final icon asset only, transparent outside squircle, no text, no letters, no words, no typography, no border, no watermark, no mockup scene, no giant lens, no cyclops, no landscape or photo card, no busy background, no gradients of rainbow colors, no tiny UI details. Must look like a refined macOS app icon, not a screenshot.
```

## Background refinement prompt

Built-in imagegen edit mode; opaque output. Native packaging supplies the clean outer mask.

```text
Use case: precise-object-edit.
Asset type: production source artwork for a macOS app icon.
Edit target: the attached coral NotchShot app icon.
Primary request: Preserve the coral screen character, face, tiny dark top notch, warm white sparkle, soft 3D material and composition exactly. Change ONLY the outer background: extend the warm ivory tile color and shading all the way to the four straight square canvas edges. Remove the tile's rounded silhouette, all transparency, all outer margins, and all specks/fringing outside the tile. The final image must be a fully opaque 1024x1024 square of continuous warm ivory behind the unchanged centered coral character. Keep the character and sparkle in precisely their current relative positions and scale. We will apply the exact macOS outer icon silhouette later during native packaging. No border, no text, no new objects.
```
