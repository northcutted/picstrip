# PicStrip Privacy Policy
**Last updated: September 19, 2026**

## Overview
PicStrip is a privacy-focused app. All photo processing happens entirely on your device, and no network connection is required to use it. We do not collect, store, transmit, or share any of your data. The only thing PicStrip can ever cause to be transferred is an Apple on-device model, downloaded by iOS after you explicitly agree — described under "Optional Object Selection Model" below.

## What We Do Not Collect
- Photos or image files
- Metadata stripped from photos
- Location data
- Face data
- Usage data or analytics
- Device identifiers
- Any personal information

## On-Device Processing Only
When you use PicStrip to remove metadata from a photo or redact sensitive visual content, all processing occurs locally on your iPhone or iPad. No photo, metadata, OCR text, recognised name, barcode payload, face detection result, or redaction coordinate ever leaves your device through PicStrip.

## Face Data
PicStrip does not collect face data. When PicStrip scans a photo, it uses Apple's on-device Vision face-rectangle detector to find where faces appear in that photo so the app can show redaction boxes and, if you choose, burn those redactions into the cleaned copy.

PicStrip does not identify people, perform face recognition, compare faces across photos, create faceprints or biometric templates, infer identity, or use face landmarks/profiles. The only face-related result used by the app is a temporary bounding rectangle for each face detected in the photo being processed.

Face detection results are used only for the current on-device editing and export flow. They are not uploaded, transmitted, shared with third parties, written to PicStrip servers, written to third-party servers, or retained by PicStrip after the current photo/session is cleared. If you save a cleaned image, the saved file is stored in your own Photos library according to your device settings; PicStrip does not store a separate copy or any separate face data.

## Camera and Document Scanning
PicStrip asks for camera access only when you tap "Take Photo" or "Scan Document". "Scan Document" uses Apple's system document scanner. "Take Photo" uses PicStrip's own viewfinder, which runs on your device; if it cannot start, the system camera is used instead. Either way the capture is handed to PicStrip in memory, where it goes through the same on-device detection and redaction as any other image.

PicStrip never saves the original, un-redacted photo or scan to your photo library and keeps no copy of it: it is discarded when you finish or cancel the session. Only the cleaned copy you explicitly choose to save or share leaves the editor. Nothing from the camera is uploaded, transmitted, or shared.

While the "Take Photo" viewfinder is open, PicStrip analyses camera frames on your device to show, live, which areas it would redact. Each frame is examined in memory and discarded at once; no frame and no result of that analysis is stored.

## Names and Apple Intelligence
Where you have turned Apple Intelligence on, PicStrip asks Apple's on-device language model to find people's names in the text it recognised in your photo. This runs entirely on your device. PicStrip never uses Apple's Private Cloud Compute or any other server for it, and downloads nothing for it. Where Apple Intelligence is off or unavailable, names are simply not detected.

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
