# App Review Face Data Response

Submission ID: 81f8c840-f3c2-433e-a7e3-3759947f1ec3  
Review date: May 14, 2026  
Version reviewed: 1.6.2 (62)

## What face data does the app collect?

PicStrip does not collect face data. When visual redaction is enabled, the app uses Apple's on-device Vision face-rectangle detector (`VNDetectFaceRectanglesRequest`) to find where faces appear in the current photo. The app uses only temporary bounding rectangles for the current photo. It does not collect face images, faceprints, biometric templates, face embeddings, landmarks, identity, names, or recognition profiles.

## Planned uses of face data

The temporary face bounding rectangles are used only to show editable redaction boxes and, if the user chooses to save/share the cleaned image, to burn those redactions into the output image. The app may also use the presence of a face as one local signal when ranking whether a document-like photo may contain sensitive identity content. PicStrip does not identify people, compare faces, track people, authenticate users, personalize content, train models, or use face data for analytics or advertising.

## Third-party sharing and storage

Face data is not shared with any third parties. It is not uploaded, transmitted, or stored on PicStrip servers or third-party servers. PicStrip does not use third-party SDKs, analytics, advertising, or crash reporting. Processing happens on device. The only persistent output is the cleaned image the user explicitly saves to their own Photos library or shares through the system share sheet.

## Retention

PicStrip does not retain face data. Face detection results exist only in memory for the current photo/session so the user can review and edit redactions. They are discarded when the photo is cleared, the session ends, or the app state is reset. PicStrip does not keep photo history, face rectangles, redaction coordinates, OCR snippets, removed metadata values, or separate face data records.

## Privacy policy location and quoted text

The collection, use, disclosure, sharing, storage, and retention of face data are explained in the privacy policy sections "On-Device Processing Only", "Face Data", and "Third-Party Services":

> PicStrip does not collect face data. When visual redaction is enabled, PicStrip uses Apple's on-device Vision face-rectangle detector to find where faces appear in the current photo so the app can show redaction boxes and, if you choose, burn those redactions into the cleaned copy.

> PicStrip does not identify people, perform face recognition, compare faces across photos, create faceprints or biometric templates, infer identity, or use face landmarks/profiles. The only face-related result used by the app is a temporary bounding rectangle for each face detected in the photo being processed.

> Face detection results are used only for the current on-device editing and export flow. They are not uploaded, transmitted, shared with third parties, written to PicStrip servers, written to third-party servers, or retained by PicStrip after the current photo/session is cleared.
