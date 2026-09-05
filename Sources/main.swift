import Cocoa
import CoreImage
import CoreImage.CIFilterBuiltins
import ScreenCaptureKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, SCStreamOutput, SCStreamDelegate {
    private var windows: [NSWindow] = []
    private var streams: [SCStream] = []

    // Each stream has its own output view.
    private var streamViews: [ObjectIdentifier: FilterView] = [:]

    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false
    ])

    private let queue = DispatchQueue(
        label: "HueShift.frames",
        qos: .userInteractive
    )

    private let angleLock = NSLock()
    private var _angle: Float = 0

    private var angle: Float {
        get {
            angleLock.lock()
            defer { angleLock.unlock() }
            return _angle
        }
        set {
            angleLock.lock()
            _angle = newValue
            angleLock.unlock()
        }
    }

    private var controlWindow: NSWindow!
    private var slider: NSSlider!
    private var valueLabel: NSTextField!
    private var statusLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestScreenCapture()
    }

    private func requestScreenCapture() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )

                await MainActor.run {
                    self.createOutputWindows(for: content.displays)
                    self.makeControls()
                }

                // The output windows did not exist when the first
                // SCShareableContent query was performed. Refresh the
                // ScreenCaptureKit content list so that those windows can
                // be identified and excluded from their corresponding
                // capture streams.
                let refreshedContent =
                    try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: false
                    )

                await MainActor.run {
                    self.startStreams(
                        for: content.displays,
                        content: refreshedContent
                    )
                }
            } catch {
                await MainActor.run {
                    self.showError(
                        "Screen Recording permission is required. Enable HueShift in System Settings > Privacy & Security > Screen Recording, then relaunch."
                    )
                }
            }
        }
    }

    // MARK: - Output windows

    private func createOutputWindows(for displays: [SCDisplay]) {
        for display in displays {
            let frame = NSScreen.screens.first(where: { screen in
                let id = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID

                return id == display.displayID
            })?.frame ?? CGRect(
                x: 0,
                y: 0,
                width: 1920,
                height: 1080
            )

            let filterView = FilterView(
                frame: CGRect(
                    origin: .zero,
                    size: frame.size
                )
            )

            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            window.level = .screenSaver

            window.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary
            ]

            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.contentView = filterView

            // Keep the window hidden until the corresponding capture stream
            // has been created. This prevents an unnecessary transition
            // frame from appearing before ScreenCaptureKit is configured.
            window.orderFrontRegardless()

            windows.append(window)
        }
    }

    // MARK: - Screen capture

    private func startStreams(
        for displays: [SCDisplay],
        content: SCShareableContent
    ) {
        for display in displays {
            guard let outputWindow = windowForDisplay(display) else {
                continue
            }

            guard let outputView = outputWindow.contentView as? FilterView else {
                continue
            }

            // Find the ScreenCaptureKit representation of our actual
            // output window. SCContentFilter requires SCWindow here,
            // not NSWindow.
            let outputWindowID = CGWindowID(outputWindow.windowNumber)

            guard let scOutputWindow = content.windows.first(where: {
                $0.windowID == outputWindowID
            }) else {
                showError(
                    "Could not identify the HueShift output window in ScreenCaptureKit."
                )
                return
            }

            guard let displayContent = content.displays.first(where: {
                $0.displayID == display.displayID
            }) else {
                continue
            }

            let frame = outputWindow.frame

            let config = SCStreamConfiguration()

            config.width = max(
                1,
                Int(frame.width * 2)
            )

            config.height = max(
                1,
                Int(frame.height * 2)
            )

            config.minimumFrameInterval = CMTime(
                value: 1,
                timescale: 60
            )

            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.capturesAudio = false
            config.ignoreShadowsSingleWindow = true

            // Exclude the exact output window belonging to this stream.
            //
            // This prevents:
            //
            // Display -> capture -> hue filter -> output window
            //          ^                         |
            //          |_________________________|
            //
            // from becoming a recursive feedback loop.
            let streamFilter = SCContentFilter(
                display: displayContent,
                excludingApplications: [],
                exceptingWindows: [scOutputWindow]
            )

            do {
                let stream = SCStream(
                    filter: streamFilter,
                    configuration: config,
                    delegate: self
                )

                try stream.addStreamOutput(
                    self,
                    type: .screen,
                    sampleHandlerQueue: queue
                )

                streams.append(stream)

                let streamID = ObjectIdentifier(stream)
                streamViews[streamID] = outputView

                Task {
                    do {
                        try await stream.startCapture()

                        await MainActor.run {
                            outputWindow.orderFrontRegardless()
                        }
                    } catch {
                        await MainActor.run {
                            self.statusLabel?.stringValue =
                                "Capture error: \(error.localizedDescription)"
                        }
                    }
                }
            } catch {
                showError(
                    "Could not configure screen capture: \(error.localizedDescription)"
                )
            }
        }
    }

    private func windowForDisplay(_ display: SCDisplay) -> NSWindow? {
        guard let screen = NSScreen.screens.first(where: { screen in
            let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID

            return id == display.displayID
        }) else {
            return nil
        }

        let screenFrame = screen.frame

        return windows.first(where: {
            $0.frame == screenFrame
        })
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else {
            return
        }

        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let ciImage = CIImage(
            cvPixelBuffer: imageBuffer
        )

        let filter = CIFilter.hueAdjust()

        filter.inputImage = ciImage
        filter.angle = angle * .pi / 180.0

        guard let output = filter.outputImage else {
            return
        }

        let extent = ciImage.extent

        guard let cgImage = ciContext.createCGImage(
            output,
            from: extent
        ) else {
            return
        }

        let streamID = ObjectIdentifier(stream)

        DispatchQueue.main.async {
            guard let view = self.streamViews[streamID] else {
                return
            }

            view.image = cgImage
            view.needsDisplay = true
        }
    }

    // MARK: - SCStreamDelegate

    func stream(
        _ stream: SCStream,
        didStopWithError error: Error
    ) {
        let streamID = ObjectIdentifier(stream)

        DispatchQueue.main.async {
            self.streamViews.removeValue(forKey: streamID)

            self.statusLabel?.stringValue =
                "Capture stopped: \(error.localizedDescription)"
        }
    }

    // MARK: - Controls

    private func makeControls() {
        let width: CGFloat = 330
        let height: CGFloat = 145

        controlWindow = NSWindow(
            contentRect: NSRect(
                x: 40,
                y: 40,
                width: width,
                height: height
            ),
            styleMask: [
                .titled,
                .closable,
                .utilityWindow
            ],
            backing: .buffered,
            defer: false
        )

        controlWindow.title = "HueShift"
        controlWindow.isReleasedWhenClosed = false
        controlWindow.level = .floating

        let view = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )
        )

        let title = NSTextField(
            labelWithString: "Display hue"
        )

        title.frame = NSRect(
            x: 20,
            y: 108,
            width: 100,
            height: 22
        )

        valueLabel = NSTextField(
            labelWithString: "0°"
        )

        valueLabel.alignment = .right

        valueLabel.frame = NSRect(
            x: 270,
            y: 108,
            width: 40,
            height: 22
        )

        slider = NSSlider(
            value: 0,
            minValue: -180,
            maxValue: 180,
            target: self,
            action: #selector(sliderChanged(_:))
        )

        slider.frame = NSRect(
            x: 20,
            y: 72,
            width: 290,
            height: 24
        )

        slider.isContinuous = true

        let reset = NSButton(
            title: "Reset",
            target: self,
            action: #selector(resetHue)
        )

        reset.frame = NSRect(
            x: 20,
            y: 35,
            width: 80,
            height: 28
        )

        statusLabel = NSTextField(
            labelWithString: "Screen capture active"
        )

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        statusLabel.frame = NSRect(
            x: 115,
            y: 37,
            width: 195,
            height: 22
        )

        view.addSubview(title)
        view.addSubview(valueLabel)
        view.addSubview(slider)
        view.addSubview(reset)
        view.addSubview(statusLabel)

        controlWindow.contentView = view
        controlWindow.center()
        controlWindow.makeKeyAndOrderFront(nil)

        NSApp.activate(
            ignoringOtherApps: true
        )
    }

    @objc private func sliderChanged(
        _ sender: NSSlider
    ) {
        angle = Float(
            sender.doubleValue
        )

        valueLabel.stringValue = String(
            format: "%.0f°",
            sender.doubleValue
        )
    }

    @objc private func resetHue() {
        slider.doubleValue = 0
        sliderChanged(slider)
    }

    // MARK: - Errors

    private func showError(
        _ message: String
    ) {
        let alert = NSAlert()

        alert.messageText = "HueShift"
        alert.informativeText = message
        alert.alertStyle = .warning

        alert.runModal()

        NSApp.terminate(nil)
    }

    // MARK: - Shutdown

    func applicationWillTerminate(
        _ notification: Notification
    ) {
        for stream in streams {
            Task {
                try? await stream.stopCapture()
            }
        }

        streams.removeAll()
        streamViews.removeAll()
        windows.removeAll()
    }
}

// MARK: - Filter view

final class FilterView: NSView {
    var image: CGImage?

    override func draw(
        _ dirtyRect: NSRect
    ) {
        guard let image else {
            return
        }

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }

        ctx.interpolationQuality = .none

        ctx.draw(
            image,
            in: bounds
        )
    }
}

// MARK: - Application

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.run()
