## Summary

<!-- What changed and why. Link the issue if there is one: Fixes #123 -->

## Testing

<!-- Commands you ran, plus any manual verification (display layouts, permissions, etc.). -->

- [ ] `swift test`
- [ ] Built and ran the `.app` bundle where the change affects capture, recording, or permissions
- [ ] Verified behavior on a second display or non-notch display where relevant

## Privacy and permissions

- [ ] No capture, recording, OCR, clipboard content, or real user paths are included in the code, tests, fixtures, or this PR
- [ ] Redaction still burns pixels before crop, rotation, annotation, and export
- [ ] No new network calls without an explicit user action
- [ ] Permissions are still requested just-in-time, never at launch
- [ ] Experimental integrations (OSD replacement, media adapter, clipboard) remain opt-in and fail open

## Notes for reviewers

<!-- Trade-offs, follow-ups, or areas you want a second opinion on. -->
