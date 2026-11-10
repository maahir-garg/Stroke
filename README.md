# Stroke

An iOS app that tracks index fingertips from the camera using Vision hand-pose detection. It is derived from Apple's sample code project "Detecting Hand Poses with Vision" (WWDC20 session 10653, Detect Body and Hand Pose with Vision), which draws virtual ink strokes from a thumb and index finger pinch. The original sample's history is preserved in this repository, starting with Apple's commits.

Status: experiment, not maintained.

## What it does

- Captures video with AVFoundation and runs a Vision hand-pose request on each frame.
- Reads the index fingertip of each detected hand and draws it over the camera preview.
- Start and Stop buttons begin and end a tracking run. While running, each fingertip's path is drawn as a coloured trail and its points are stored with timestamps.
- On Stop, the run is exported as a JSON file, plus a PNG snapshot of the preview with the trails, through the iOS share sheet.
- A Flip button switches between the back and front cameras.
- The original pinch-to-draw classes (`HandGestureProcessor` and the stroke drawing code in `CameraViewController`) are still in the project; the current tracking path does not use them.

## Requirements

- Xcode that supports the iOS 18.6 SDK. The deployment target of the app target is iOS 18.6.
- A device with a camera. The Info.plist allows landscape-right orientation only.
- Camera permission, requested on first launch.
- No third-party dependencies.

## Run it

1. Open `Stroke.xcodeproj` in Xcode.
2. Select the `Stroke` target and set your own team under Signing & Capabilities. The project file contains the original author's team and bundle identifier.
3. Choose a connected device and run.

## Layout

- `Stroke/CameraViewController.swift`: capture session, Vision request, fingertip tracking, trails and JSON export.
- `Stroke/CameraView.swift`: camera preview view and point overlay.
- `Stroke/HandGestureProcessor.swift`: pinch state machine from the original sample.
- `Stroke/AppDelegate.swift`, `Stroke/SceneDelegate.swift`: app lifecycle.
- `Stroke/Base.lproj/`: storyboards.
- `Configuration/SampleCode.xcconfig`, `Stroke.xcodeproj/.xcodesamplecode.plist`: configuration files from Apple's sample.

## Credits

This project started from Apple's sample code "Detecting Hand Poses with Vision" (Copyright 2024 Apple Inc., republished 2024-07-01). Apple's sample code was released under a permissive licence, and its notice is reproduced in `LICENSE.txt`. The changes after that point are in commits by Maahir Garg: the rewrite of `CameraViewController.swift` to track index fingertips and export JSON, and a later change to camera selection.

## Licence

See `LICENSE.txt`. It contains Apple's original notice for the sample code, followed by the MIT licence that covers the changes made here.
