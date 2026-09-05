# HueShift

A small native macOS utility that applies a true hue rotation to the entire captured display.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Xcode Command Line Tools (`xcode-select --install`)

## Build

From Terminal:

    cd /path/to/HueShift
    ./build.sh

The app asks for Screen Recording permission. Enable it in:

System Settings > Privacy & Security > Screen Recording

Then quit and relaunch HueShift.

## Use

The utility captures each display, applies Core Image's `CIHueAdjust` filter, and displays the result in a full-screen window. The control window provides a -180° to +180° slider.

## Important limitations

This is a software display filter, not a WindowServer or GPU display-pipeline hook.

- Screen Recording permission is required.
- There is capture/render latency.
- Protected content that macOS does not expose to ScreenCaptureKit cannot be transformed.
- HDR and wide-gamut behavior can differ from the native display pipeline.
- The mouse cursor is captured and transformed as part of the frame.
- The output window ignores mouse events, so normal mouse input passes through to applications underneath.
- The app can consume significant GPU bandwidth at high-resolution 60 Hz capture.

Core Image's `CIHueAdjust` performs the desired color-cube rotation. Apple documents its angle parameter in radians.
