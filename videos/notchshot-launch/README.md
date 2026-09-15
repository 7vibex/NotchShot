# NotchShot launch video

Reference-led 69-second product walkthrough at 1920×1080. Uses unchanged real NotchShot screenshots, rounded composition masks, a scripted cursor, and an original instrumental score.

## Files

- `index.html`: editable HyperFrames composition and seekable timeline.
- `BRIEF.md`, `STORYBOARD.md`, `frame.md`: intent, scenes, and design direction.
- `assets/`: local screenshot assets, GSAP runtime, and original music.
- `scripts/create-score.mjs` and `scripts/create-ui-sounds.mjs`: reproducible local audio generators.
- `reports/REFERENCE_ANALYSIS.md`: timestamped reference analysis, research links, and proof limits.
- `reports/index.html`: all-frame contact-sheet browser.
- `reports/reference-2056-frames.zip`: all 2,056 original-size JPEG reference frames (local evidence; ignored by Git).
- `renders/notchshot-launch.mp4`: final video after rendering.

## Reproduce

```sh
node scripts/create-score.mjs
node scripts/create-ui-sounds.mjs
npm run check
npx --yes hyperframes@0.8.37 snapshot --at 1,5,9,13,19,24,32,37,43,48,52,56,60,66,68
npm run render -- --fps 30 --quality high --output renders/notchshot-launch.mp4
npx --yes hyperframes@0.8.37 preview --background
```

Node.js 22+ and FFmpeg are required. HyperFrames is pinned at 0.8.37; GSAP 3.14.2 is vendored locally. The screenshot assets remain original; masking is performed at composition time so black product chrome is retained while the rectangular desktop background is excluded.

The interaction is staged for explanation and pacing. It is not a continuous screen recording, and does not prove the underlying capture/copy/audio operations were executed during video production. No application source files were modified.
