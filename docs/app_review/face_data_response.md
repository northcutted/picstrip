# Face-data explanation for App Review

Updated for the replacement 1.7.0 source. This supersedes the response prepared for version 1.6.2 on 14 May 2026. It is a local draft until included in the approved submission.

PicStrip uses Apple's on-device Vision face-rectangle detection to suggest regions to cover. Temporary rectangles help users review and edit the current image, and can contribute to local document-context detection. PicStrip does not identify people, compare faces, create faceprints or biometric templates, authenticate users, train models, or use faces for analytics or advertising. Optional name suggestions come from recognized text, not facial identification.

The app does not send photos, face rectangles or recognized text to a developer-operated service. Face rectangles and scan results are held in memory for the current editing session and are cleared with that session. Live-camera frames are processed in memory for an advisory preview; the captured photo receives a full scan before review.

Users can deliberately save or share a processed image. Those copies can still contain faces or other information the user leaves visible. Saving to a synced Photos library and sharing to another app follow the selected service's settings. The app does not automatically save an unreviewed camera capture to Photos.

An extension-to-app edit handoff can temporarily contain the original photo, including faces. The local file has complete file protection, is excluded from backups, expires after 15 minutes, and is removed on consumption or cancellation. Expired records are removed on subsequent app/extension access. Temporary exported image/report files are also protected and cleaned up on completion where possible, with an expiry sweep as a fallback. Reports contain names of metadata fields, counts and coverage status, not original values or recognized text.

The public policy is [PRIVACY.md](../../PRIVACY.md). Review its current face-data, storage and user-directed sharing sections rather than submitting quotations from an older policy.
