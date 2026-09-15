# NotchShot — faster feature cut

Separate42-second1920×1080 version of the original launch film. Faster action pacing, more features, fresh native Claude compact/hover/detail screenshots, Window Snap and System Stats. Original music128BPM. First video remains unchanged in `../notchshot-launch`.

## Deliverables

- `renders/notchshot-fast.mp4`: final rendered film.
- `assets/claude-bar.png`, `assets/claude-hover.png`, `assets/claude-details.png`: fresh Claude captures.
- `reports/CAPTURE_NOTES.md`: screenshot provenance and demo cleanup.
- `STORYBOARD.md`: timing and scenes.
- `index.html`: editable composition.

## Reproduce

```sh
node scripts/create-score.mjs
npm run check
npm run render -- --fps 30 --quality high --output renders/notchshot-fast.mp4
```

HyperFrames pinned0.8.37; local GSAP. Original screenshot assets are preserved, with composition-time masking. This is an animated screenshot walkthrough, not a continuous app recording. No app source changes, deployment, or publishing.
