# PicStrip Privacy Policy
**Last updated: September 19, 2026**

## Overview
PicStrip is a privacy-focused app. All photo processing happens entirely on your device. We do not collect, store, transmit, or share any of your data.

## What We Do Not Collect
- Photos or image files
- Metadata stripped from photos
- Location data
- Face data
- Usage data or analytics
- Device identifiers
- Any personal information

## On-Device Processing Only
When you use PicStrip to remove metadata from a photo or redact sensitive visual content, all processing occurs locally on your iPhone or iPad. No photo, metadata, OCR text, barcode payload, face detection result, or redaction coordinate ever leaves your device through PicStrip.

## Face Data
PicStrip does not collect face data. When visual redaction is enabled, PicStrip uses Apple's on-device Vision face-rectangle detector to find where faces appear in the current photo so the app can show redaction boxes and, if you choose, burn those redactions into the cleaned copy.

PicStrip does not identify people, perform face recognition, compare faces across photos, create faceprints or biometric templates, infer identity, or use face landmarks/profiles. The only face-related result used by the app is a temporary bounding rectangle for each face detected in the photo being processed.

Face detection results are used only for the current on-device editing and export flow. They are not uploaded, transmitted, shared with third parties, written to PicStrip servers, written to third-party servers, or retained by PicStrip after the current photo/session is cleared. If you save a cleaned image, the saved file is stored in your own Photos library according to your device settings; PicStrip does not store a separate copy or any separate face data.

## Camera and Document Scanning
PicStrip asks for camera access only when you tap "Take Photo" or "Scan Document". The capture is handled by Apple's system camera and handed to PicStrip in memory, where it goes through the same on-device detection and redaction as any other image.

PicStrip never saves the original, un-redacted photo or scan to your photo library and keeps no copy of it: it is discarded when you finish or cancel the session. Only the cleaned copy you explicitly choose to save or share leaves the editor. Nothing from the camera is uploaded, transmitted, or shared.

## Optional Object Selection Model
On iOS 27 you can tap an object to redact it. That uses an Apple on-device model which iOS downloads from Apple the first time — and only after PicStrip has asked and you have agreed. Only the model is downloaded. Your photo is analysed on your device like everything else; nothing about it is sent anywhere. If you decline, nothing is downloaded and you can still draw redaction boxes by hand.

## Third-Party Services
PicStrip does not use any third-party SDKs, analytics tools, advertising networks, or crash reporting services.

## Share Extension
The PicStrip Share Extension processes photos shared from other apps entirely on-device. No data is sent anywhere.

## Open Source
PicStrip is open source. You can inspect exactly how your photos are handled.

## Contact
Questions? [Open an Issue](https://github.com/northcutted/picstrip/issues/new)
