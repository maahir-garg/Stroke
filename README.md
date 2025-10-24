Stroke — Virtual Drawing with Hand Pose Detection

Stroke is an iOS sample app that turns hand poses and gestures captured from the camera into virtual ink strokes. It demonstrates how to use the Vision framework to detect hand landmarks and convert fingertip movement into a drawing experience.

## Highlights
- Real-time hand pose detection using Vision.
- Converts fingertip tracking into continuous drawing (virtual stroke) on screen.
- Lightweight Swift sample suitable as a foundation for gesture-driven apps.

## Features
- Detects hand landmarks (fingertips, joints) using Vision's hand pose API.
- Processes gestures via `HandGestureProcessor.swift` to start/stop strokes and smooth points.
- Camera capture and preview handled in `CameraView.swift` / `CameraViewController.swift`.

## Requirements
- Xcode 12 or later (project contains a modern Swift codebase).
- iOS 13.0+ (uses SceneDelegate and modern lifecycle APIs).
- A device or simulator with camera access (simulator can use a connected camera feed where available).

## Privacy
This app requires camera access. Make sure `NSCameraUsageDescription` is set in `Info.plist` (it is included in the project). When running on-device, grant camera permission when prompted.

## Build & Run
1. Open `Stroke.xcodeproj` in Xcode or open the workspace if you prefer the workspace file.
2. Select a target device (a physical iPhone is recommended for camera functionality).
3. Build and run. Grant camera permission when prompted.

Tip: To iterate quickly, build for a device running iOS 13+ so the app can access the live camera feed and Vision APIs.

## Project structure (key files)
- `AppDelegate.swift`, `SceneDelegate.swift` — app lifecycle.
- `CameraView.swift`, `CameraViewController.swift` — capture and preview pipeline.
- `HandGestureProcessor.swift` — converts Vision observations into drawing state/gestures.
- `Assets.xcassets/` — app icons and color assets.
- `Info.plist` — app configuration and privacy keys.

## How it works (brief)
1. Camera frames are captured and forwarded to Vision for hand pose detection.
2. Vision returns hand landmark points (normalized coordinates).
3. `HandGestureProcessor` maps landmark points to screen coordinates, smooths movement, and emits stroke start/continue/end events.
4. The UI layer draws strokes in response to those events.

## License
This project is released under the MIT License — see `LICENSE.txt` for details.

## Contact
Repository owner: maahir-garg
Project created: 2020 (sample origin) — updated 2025

Enjoy experimenting with hand-driven interactions!
