# PicStrip Privacy Policy
**Last updated: October 2, 2026**

## Overview
PicStrip processes photos and videos on your iPhone or iPad. We operate no photo-processing server and collect no photos, metadata, location, face data, recognised text, usage analytics, or advertising identifiers. No account is required.

You decide what to save or share. Sending an image or report through the system share sheet gives it to the destination you select. Saving to Photos or Files may sync it through services enabled in your device settings, such as iCloud. Images you choose from a cloud photo library or file provider may need to download first. Those services follow their own privacy policies.

## On-Device Processing Only
Metadata inspection, text recognition, pattern matching, face and barcode detection, and image redaction run locally. PicStrip does not upload your images or scan results for processing. Core editing works offline once the image is available on your device.

Automatic detection can miss sensitive details. Review the entire image before sharing. Name suggestions are not covered automatically. Metadata you explicitly choose to keep, and visible content you leave uncovered, can remain in your exported image. The review screen shows incomplete checks and retained information; it is not a guarantee that every private detail has been found.

## Face Data
PicStrip uses Apple's on-device Vision face-rectangle detector to locate faces in the current image or camera frame. It uses temporary bounding rectangles to display editable boxes and apply the redactions you select.

PicStrip does not identify people, compare faces, create faceprints, biometric templates, embeddings, landmarks or recognition profiles, or use face data for authentication, analytics, advertising or model training. Face presence may contribute to the local assessment of document-like content.

Detection rectangles and recognised text are held in memory for the current editing session and discarded when that session is cleared. PicStrip keeps no history of scan results or separate face records. Your saved or shared image can still contain a face if it was missed or you chose not to cover it.

## Camera, Microphone and Document Scanning
PicStrip requests camera access when you open its camera, and microphone access the first time you record a video. Photo mode uses an on-device viewfinder, with Apple's camera as a fallback; Document mode uses Apple's document scanner. Captures enter the current editing session without being saved as originals to your photo library.

Video mode writes the recording, with its sound, to PicStrip's protected temporary storage and opens it to be cleaned. It is not saved to your photo library as it is: only a cleaned copy you choose to save or share leaves PicStrip, and the recording is deleted when you close the video screen — PicStrip asks first if you have not saved a copy. PicStrip does not add your location to recordings. If you do not allow the microphone, videos are recorded without sound.

Live camera analysis is a guide. Frames and their detections are not recorded. After capture, the full still image is scanned for review. PicStrip saves or shares a copy only when you ask it to. Clearing the session discards the in-memory original.

Screenshots and videos are chosen with Apple's photo picker, which hands PicStrip only the items you pick; PicStrip does not read your photo library.

## Videos and Live Photos
When you clean a video, PicStrip copies it into protected temporary storage, looks for faces, sensitive text, codes and your Always Cover words in it on your device, and writes a copy without its location, device, software and date metadata. What it finds, and any object you draw around, is covered in the copy unless you choose to leave it visible, and any stretch of sound you bleep or mute is replaced in the copy; this means the video is re-encoded. Anything missed stays visible. If nothing is found, or you skip covering, the frames are copied unchanged. PicStrip checks the copy and does not keep it if any of those details remain. Both files are deleted when you close the video screen.

If you clean several videos at once, each is copied into protected temporary storage in turn, cleaned the same way without your review — every face found blurred and sensitive text and codes covered, if you choose covering — saved to your photo library, and its temporary files deleted before the next.

If you keep a Live Photo's motion, its video is cleaned the same way, except for a random identifier that pairs it with the still photo. The motion is not covered, so PicStrip offers it only when nothing in the photo is covered.

## Always Cover
Words and phrases you add to Always Cover — your name or a license plate, for example — are the only information PicStrip keeps between launches. They are stored in one file inside PicStrip's own storage on your device, encrypted while the device is locked and excluded from backups. They are not uploaded, not shared with the Share Extension, and used only to find and cover those words in your images. You can delete them at any time in Always Cover.

## Names and Apple Intelligence
On supported devices with Apple Intelligence available, PicStrip uses Apple's on-device language model to suggest people's names found in recognised text. These suggestions are optional to cover. PicStrip does not use Private Cloud Compute for this feature or upload the recognised text. The scan status distinguishes unavailable or incomplete name checks from completed checks.

## Optional Object Selection Model
On iOS 27, tapping an object to select it may require an Apple Vision model. PicStrip asks before requesting its download from Apple. The downloaded model runs on device; your photo is not uploaded for object selection. You can decline and draw or position boxes manually.

## Temporary Files and Share Extension
The Share Extension can save cleaned copies or prepare the first original image for manual editing in PicStrip. An editing handoff contains that original image, including its original metadata. It is stored in a protected local app-group directory, excluded from backups, and removed when imported or explicitly discarded. Handoffs become ineligible for import after 15 minutes; expired files are deleted on the next cleanup or access. Preparing another image does not overwrite an existing handoff.

Temporary export files and reports use neutral filenames, iOS complete file protection, and directories excluded from backups. Shared reports contain field names, counts and scan status, not removed metadata values, recognised text or redaction coordinates. Report files are deleted when their share activity ends. Background Shortcuts return file-backed images that request deletion when the Shortcut finishes. A cleanup pass also removes export files older than one hour when the app is running or those files are next accessed. iOS may suspend or terminate the app, so cleanup is not guaranteed at the exact expiry time.

Copies saved to Photos, Files, or another app are controlled by you and that destination. PicStrip's temporary-file cleanup does not delete those copies.

## Shortcuts
The background “Strip Metadata from Images” action removes metadata and returns cleaned files. It does not detect or redact visible text or faces. The actions that open PicStrip — to clean photos, take a photo or clean a screenshot — let you review visible content in the app.

## Third-Party Services
PicStrip includes no third-party analytics, advertising or crash-reporting SDKs. Opening support or source-code links uses your browser. System photo/file providers, Apple model downloads, and destinations you select for sharing may use the network; PicStrip does not send your images to a developer-operated service.

## Open Source and Contact
You can inspect the source on [GitHub](https://github.com/northcutted/picstrip). For questions, [open an issue](https://github.com/northcutted/picstrip/issues/new). Avoid attaching private photos or personal information to public issues.
