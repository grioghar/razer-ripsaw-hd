import AVFoundation
import AppKit
import CoreImage

// MARK: - Adjustable image settings (shared between UI and frame pipeline)

struct VideoAdjustments {
    var brightness: Double = 0   // CIColorControls, -0.5 ... 0.5
    var contrast: Double = 1     // 0.5 ... 1.5
    var saturation: Double = 1   // 0 ... 2
    var mirrorH = false
    var flipV = false
    var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && !mirrorH && !flipV
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate,
                         AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: Capture
    private var window: NSWindow!
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "capture.session")
    private let frameQueue = DispatchQueue(label: "capture.frames")
    private let audioQueue = DispatchQueue(label: "capture.audio")
    private var videoDevice: AVCaptureDevice?
    private var displayLayer: AVSampleBufferDisplayLayer!
    private let ciContext = CIContext()
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    // MARK: UI
    private var railView: NSVisualEffectView!
    private var recordButton: NSButton!
    private var recordMenuItem: NSMenuItem!
    private var sizePopup: NSPopUpButton!
    private var formatPopup: NSPopUpButton!
    private var brightnessSlider: NSSlider!
    private var contrastSlider: NSSlider!
    private var saturationSlider: NSSlider!
    private var mirrorButton: NSButton!
    private var flipButton: NSButton!
    private var debugButton: NSButton!
    private var debugField: NSTextField!
    private var hideRailTimer: Timer?
    private var uiTick = 0
    private var reconfigurePending = false
    private var zeroFrameSeconds = 0

    // MARK: Shared state (guarded by stateLock)
    private let stateLock = NSLock()
    private var adjustments = VideoAdjustments()
    private var frameCount = 0
    private var lastBrightness: Double = -1
    private var lastFrameTime = CFAbsoluteTimeGetCurrent()
    private var displayBlanked = false // main thread only
    private var noSignalField: NSTextField!

    // MARK: Recording (guarded by writerLock)
    private let recordingSizes: [(name: String, width: Int?, height: Int?)] = [
        ("Native", nil, nil), ("1080p", 1920, 1080), ("720p", 1280, 720), ("480p", 854, 480),
    ]
    private let writerLock = NSLock()
    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerAudioInput: AVAssetWriterInput?
    private var writerSessionStarted = false
    private var recordingStart: Date?
    private var recordingURL: URL?

    private var recordingsFolder: URL {
        if let path = UserDefaults.standard.string(forKey: "RecordingsFolder") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ripsaw HD")
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        buildRail()
        buildDebugField()
        buildNoSignalField()
        startUITimer()

        // Any click on the video area brings up the control rail.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.window { self.showRail() }
            return event
        }

        // Recover automatically when the card drops off USB, comes back, or the session errors.
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice, device == self.videoDevice else { return }
            diag("Ripsaw disconnected")
            self.videoDevice = nil
            self.stopRecording()
            self.displayLayer.flushAndRemoveImage()
            self.window.title = "Razer Ripsaw HD — waiting for capture card…"
            self.scheduleReconfigure()
        }
        nc.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] note in
            guard let self, self.videoDevice == nil,
                  let device = note.object as? AVCaptureDevice,
                  device.hasMediaType(.video), device.localizedName.contains("Ripsaw") else { return }
            diag("Ripsaw connected — configuring")
            self.scheduleReconfigure(after: 0.5)
        }
        nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            let err = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "?"
            diag("session runtime error: \(err)")
            self?.scheduleReconfigure(after: 1)
        }

        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    if videoOK {
                        self.configureSession()
                    } else {
                        self.fail("Camera access was denied. Enable it in System Settings → Privacy & Security → Camera, then relaunch.")
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        writerLock.lock()
        let recording = writer != nil
        writerLock.unlock()
        if recording {
            stopRecording {
                DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }
        return .terminateNow
    }

    // MARK: - Window & menu

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Razer Ripsaw HD"
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        let content = window.contentView!
        content.wantsLayer = true
        content.layer!.backgroundColor = NSColor.black.cgColor

        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = content.bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer!.addSublayer(displayLayer)

        content.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Ripsaw HD Viewer",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        recordMenuItem = fileMenu.addItem(withTitle: "Start Recording",
                                          action: #selector(toggleRecording), keyEquivalent: "r")
        recordMenuItem.target = self
        let reveal = fileMenu.addItem(withTitle: "Show Recordings in Finder",
                                      action: #selector(revealRecordings), keyEquivalent: "")
        reveal.target = self
        let folder = fileMenu.addItem(withTitle: "Set Recording Folder…",
                                      action: #selector(chooseRecordingsFolder), keyEquivalent: "")
        folder.target = self
        fileItem.submenu = fileMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        let dbg = viewMenu.addItem(withTitle: "Toggle Debug Overlay",
                                   action: #selector(toggleDebug), keyEquivalent: "d")
        dbg.target = self
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Control rail

    private func makeSlider(min: Double, max: Double, value: Double) -> NSSlider {
        let s = NSSlider(value: value, minValue: min, maxValue: max,
                         target: self, action: #selector(adjustmentsChanged))
        s.isContinuous = true
        s.controlSize = .small
        // Flexible width: the sliders absorb window resizes so the rail scales
        // with the window instead of clipping at the edges.
        s.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        s.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
        s.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return s
    }

    private func labeled(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [control, label])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .centerX
        return stack
    }

    private func buildRail() {
        railView = NSVisualEffectView()
        railView.material = .hudWindow
        railView.blendingMode = .withinWindow
        railView.state = .active
        railView.wantsLayer = true
        railView.layer!.cornerRadius = 12
        railView.layer!.masksToBounds = true
        railView.alphaValue = 0

        recordButton = NSButton(title: "● Record", target: self, action: #selector(toggleRecording))
        recordButton.bezelStyle = .rounded
        recordButton.contentTintColor = .systemRed
        recordButton.widthAnchor.constraint(equalToConstant: 96).isActive = true

        sizePopup = NSPopUpButton()
        sizePopup.controlSize = .small
        for size in recordingSizes { sizePopup.addItem(withTitle: size.name) }
        sizePopup.target = self
        sizePopup.action = #selector(railInteraction)

        formatPopup = NSPopUpButton()
        formatPopup.controlSize = .small
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        brightnessSlider = makeSlider(min: -0.5, max: 0.5, value: 0)
        contrastSlider = makeSlider(min: 0.5, max: 1.5, value: 1)
        saturationSlider = makeSlider(min: 0, max: 2, value: 1)

        mirrorButton = NSButton(title: "Mirror", target: self, action: #selector(adjustmentsChanged))
        mirrorButton.setButtonType(.pushOnPushOff)
        mirrorButton.bezelStyle = .rounded

        flipButton = NSButton(title: "Flip", target: self, action: #selector(adjustmentsChanged))
        flipButton.setButtonType(.pushOnPushOff)
        flipButton.bezelStyle = .rounded

        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetAdjustments))
        resetButton.bezelStyle = .rounded

        debugButton = NSButton(title: "Debug", target: self, action: #selector(toggleDebug))
        debugButton.setButtonType(.pushOnPushOff)
        debugButton.bezelStyle = .rounded

        let stack = NSStackView(views: [
            recordButton,
            labeled("REC SIZE", sizePopup),
            labeled("INPUT", formatPopup),
            labeled("BRIGHTNESS", brightnessSlider),
            labeled("CONTRAST", contrastSlider),
            labeled("SATURATION", saturationSlider),
            mirrorButton, flipButton, resetButton, debugButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        railView.addSubview(stack)
        railView.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(railView)
        let growWithWindow = railView.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48)
        growWithWindow.priority = NSLayoutConstraint.Priority(400)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: railView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: railView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: railView.bottomAnchor),
            railView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            railView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            // Rail tracks the window width between the sliders' min/max bounds,
            // and may never overflow the window.
            growWithWindow,
            railView.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            contrastSlider.widthAnchor.constraint(equalTo: brightnessSlider.widthAnchor),
            saturationSlider.widthAnchor.constraint(equalTo: brightnessSlider.widthAnchor),
        ])
        updateMinWindowSize()
    }

    /// The window may never shrink below the rail's minimum width, so the
    /// controls pop out fully instead of being clipped at the edges.
    private func updateMinWindowSize() {
        railView.layoutSubtreeIfNeeded()
        let minRail = railView.fittingSize.width
        let minWidth = minRail + 24
        window.contentMinSize = NSSize(width: minWidth, height: minWidth * 9 / 16)
        // If the window is already smaller (e.g. from a previous session), grow it.
        if let content = window.contentView, content.frame.width < minWidth {
            var frame = window.frame
            let delta = minWidth - content.frame.width
            frame.size.width += delta
            frame.size.height += delta * 9 / 16
            window.setFrame(frame, display: true)
        }
    }

    private func buildNoSignalField() {
        noSignalField = NSTextField(labelWithString: "NO SIGNAL")
        noSignalField.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        noSignalField.textColor = NSColor.white.withAlphaComponent(0.35)
        noSignalField.isHidden = true
        noSignalField.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(noSignalField)
        NSLayoutConstraint.activate([
            noSignalField.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            noSignalField.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    private func buildDebugField() {
        debugField = NSTextField(labelWithString: "")
        debugField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        debugField.textColor = .white
        debugField.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        debugField.drawsBackground = true
        debugField.maximumNumberOfLines = 0
        debugField.isHidden = true
        debugField.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(debugField)
        NSLayoutConstraint.activate([
            debugField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            debugField.bottomAnchor.constraint(equalTo: railView.topAnchor, constant: -10),
        ])
    }

    @objc func mouseMoved(with event: NSEvent) {
        if event.locationInWindow.y < 160 { showRail() }
    }

    private func showRail() {
        hideRailTimer?.invalidate()
        hideRailTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                self.railView.animator().alphaValue = 0
            }
        }
        guard railView.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.railView.animator().alphaValue = 1
        }
    }

    /// Poll-based fallback: tracking-area mouseMoved events don't always arrive,
    /// so the UI timer also checks the cursor position directly.
    private func pollCursorForRail() {
        guard let window, window.isVisible else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let content = window.contentView, content.bounds.contains(content.convert(inWindow, from: nil)) else { return }
        if inWindow.y < 160 { showRail() }
    }

    // MARK: - Control actions

    @objc private func railInteraction() { showRail() }

    @objc private func adjustmentsChanged() {
        stateLock.lock()
        adjustments.brightness = brightnessSlider.doubleValue
        adjustments.contrast = contrastSlider.doubleValue
        adjustments.saturation = saturationSlider.doubleValue
        adjustments.mirrorH = mirrorButton.state == .on
        adjustments.flipV = flipButton.state == .on
        stateLock.unlock()
        showRail()
    }

    @objc private func resetAdjustments() {
        brightnessSlider.doubleValue = 0
        contrastSlider.doubleValue = 1
        saturationSlider.doubleValue = 1
        mirrorButton.state = .off
        flipButton.state = .off
        adjustmentsChanged()
    }

    @objc private func toggleDebug() {
        debugField.isHidden.toggle()
        debugButton.state = debugField.isHidden ? .off : .on
        showRail()
    }

    @objc private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use for Recordings"
        panel.directoryURL = recordingsFolder
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "RecordingsFolder")
            diag("recordings folder set to \(url.path)")
        }
    }

    @objc private func revealRecordings() {
        try? FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([recordingsFolder])
    }

    @objc private func formatChanged() {
        showRail()
        guard let device = videoDevice else { return }
        let index = formatPopup.indexOfSelectedItem
        guard index >= 0 && index < device.formats.count else { return }
        writerLock.lock()
        let recording = writer != nil
        writerLock.unlock()
        if recording { stopRecording() }

        let format = device.formats[index]
        session.beginConfiguration()
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            if let fastest = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                device.activeVideoMinFrameDuration = fastest.minFrameDuration
                device.activeVideoMaxFrameDuration = fastest.minFrameDuration
            }
            device.unlockForConfiguration()
        } catch {
            diag("format switch failed: \(error.localizedDescription)")
        }
        session.commitConfiguration()
        displayLayer.flush()
        updateTitle()
        diag("switched input format to index \(index)")
    }

    // MARK: - Capture session

    private func scheduleReconfigure(after delay: TimeInterval = 2) {
        guard !reconfigurePending else { return }
        reconfigurePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.reconfigurePending = false
            self.configureSession()
        }
    }

    private func configureSession() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        zeroFrameSeconds = 0
        sessionQueue.sync { if self.session.isRunning { self.session.stopRunning() } }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        let videoDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified)
        guard let device = videoDiscovery.devices.first(where: { $0.localizedName.contains("Ripsaw") }) else {
            session.commitConfiguration()
            videoDevice = nil
            window.title = "Razer Ripsaw HD — waiting for capture card…"
            diag("Ripsaw video device not found; retrying in 2s")
            scheduleReconfigure()
            return
        }
        videoDevice = device

        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            diag(String(format: "RipsawFormat: %dx%d @ %.2f fps [%@]",
                        d.width, d.height, fps,
                        fourCCString(CMFormatDescriptionGetMediaSubType(f.formatDescription))))
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(videoInput) else { throw NSError(domain: "viewer", code: 1) }
            session.addInput(videoInput)

            // Pick the card's best format. Must happen AFTER addInput: it switches the
            // session to input-priority mode so the .high preset doesn't override it.
            let best = device.formats.max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                let fa = a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                let fb = b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return (Int(da.width) * Int(da.height), fa) < (Int(db.width) * Int(db.height), fb)
            }
            try device.lockForConfiguration()
            if let best { device.activeFormat = best }
            if let fastest = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                device.activeVideoMinFrameDuration = fastest.minFrameDuration
                device.activeVideoMaxFrameDuration = fastest.minFrameDuration
            }
            device.unlockForConfiguration()
        } catch {
            session.commitConfiguration()
            videoDevice = nil
            window.title = "Razer Ripsaw HD — waiting for capture card…"
            diag("couldn't open video input (\(error.localizedDescription)); retrying in 2s")
            scheduleReconfigure()
            return
        }

        // Audio: prefer the HDMI capture endpoint over the mic-in endpoint.
        let audioDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        let audioDevice = audioDiscovery.devices.first { $0.localizedName.contains("Ripsaw HD - Game Capture Card") }
            ?? audioDiscovery.devices.first { $0.localizedName.contains("Ripsaw") }
        if let audioDevice, let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            let monitor = AVCaptureAudioPreviewOutput()
            monitor.volume = 1.0 // plays through the system default output
            if session.canAddOutput(monitor) { session.addOutput(monitor) }
            let audioData = AVCaptureAudioDataOutput()
            audioData.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioData) { session.addOutput(audioData) }
        }

        // Video frames flow through us: adjust → display → (optionally) record.
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(dataOutput) { session.addOutput(dataOutput) }

        session.commitConfiguration()

        formatPopup.removeAllItems()
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            formatPopup.addItem(withTitle: String(format: "%d×%d @ %.0f", d.width, d.height, fps))
        }
        if let active = device.formats.firstIndex(of: device.activeFormat) {
            formatPopup.selectItem(at: active)
        }
        updateMinWindowSize() // popup width changed with real format names

        updateTitle()
        showRail() // flash the rail once so it's discoverable
        sessionQueue.async { self.session.startRunning() }
    }

    private func updateTitle() {
        guard let device = videoDevice else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = Int((1.0 / CMTimeGetSeconds(device.activeVideoMinFrameDuration)).rounded())
        window.title = "Razer Ripsaw HD — \(dims.width)×\(dims.height) @ \(fps)fps"
    }

    // MARK: - Frame pipeline

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            appendAudio(sampleBuffer)
            return
        }
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        stateLock.lock()
        frameCount += 1
        let n = frameCount
        let adj = adjustments
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        stateLock.unlock()

        var outputBuffer = sourceBuffer
        if !adj.isIdentity, let processed = process(sourceBuffer, adj) {
            outputBuffer = processed
        }
        if n % 15 == 1 { analyzeFrame(sourceBuffer) }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        display(outputBuffer, pts: pts, duration: CMSampleBufferGetDuration(sampleBuffer))
        appendVideo(outputBuffer, pts: pts)
    }

    private func process(_ buffer: CVPixelBuffer, _ adj: VideoAdjustments) -> CVPixelBuffer? {
        var image = CIImage(cvPixelBuffer: buffer)

        let orientation: CGImagePropertyOrientation?
        switch (adj.mirrorH, adj.flipV) {
        case (false, false): orientation = nil
        case (true, false):  orientation = .upMirrored
        case (false, true):  orientation = .downMirrored
        case (true, true):   orientation = .down // both flips = 180° rotation
        }
        if let orientation {
            image = image.oriented(orientation)
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        }

        if adj.brightness != 0 || adj.contrast != 1 || adj.saturation != 1 {
            let filter = CIFilter(name: "CIColorControls")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(adj.brightness, forKey: kCIInputBrightnessKey)
            filter.setValue(adj.contrast, forKey: kCIInputContrastKey)
            filter.setValue(adj.saturation, forKey: kCIInputSaturationKey)
            image = filter.outputImage ?? image
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if pixelBufferPool == nil || poolSize.width != width || poolSize.height != height {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            pixelBufferPool = pool
            poolSize = (width, height)
        }
        guard let pool = pixelBufferPool else { return nil }
        var rendered: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &rendered)
        guard let rendered else { return nil }
        ciContext.render(image, to: rendered,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return rendered
    }

    private func display(_ buffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescriptionOut: &formatDesc) == noErr, let formatDesc else { return }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: formatDesc, sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr, let sample else { return }

        if let raw = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(raw) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(raw, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }

    /// Samples a sparse grid for overall brightness (signal-health readout in the debug overlay).
    private func analyzeFrame(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let px = base.assumingMemoryBound(to: UInt8.self)
        var total = 0, samples = 0
        for y in stride(from: 0, to: h, by: max(1, h / 12)) {
            for x in stride(from: 0, to: w, by: max(1, w / 12)) {
                let off = y * bpr + x * 4
                total += Int(px[off]) + Int(px[off + 1]) + Int(px[off + 2])
                samples += 3
            }
        }
        let brightness = samples > 0 ? Double(total) / Double(samples) / 255.0 : -1
        stateLock.lock()
        lastBrightness = brightness
        stateLock.unlock()
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        writerLock.lock()
        let recording = writer != nil
        writerLock.unlock()
        if recording { stopRecording() } else { startRecording() }
        showRail()
    }

    private func startRecording() {
        guard let device = videoDevice else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let size = recordingSizes[max(0, sizePopup.indexOfSelectedItem)]
        let width = size.width ?? Int(dims.width)
        let height = size.height ?? Int(dims.height)

        try? FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = recordingsFolder.appendingPathComponent("Ripsaw \(stamp.string(from: Date())).mov")

        do {
            let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(4_000_000, width * height * 6),
                ],
            ])
            videoInput.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            audioInput.expectsMediaDataInRealTime = true
            if newWriter.canAdd(videoInput) { newWriter.add(videoInput) }
            if newWriter.canAdd(audioInput) { newWriter.add(audioInput) }

            writerLock.lock()
            writer = newWriter
            writerVideoInput = videoInput
            writerAdaptor = adaptor
            writerAudioInput = audioInput
            writerSessionStarted = false
            recordingStart = Date()
            recordingURL = url
            writerLock.unlock()

            recordButton.title = "■ Stop"
            recordMenuItem.title = "Stop Recording"
            diag("Recording started: \(url.path) at \(width)x\(height) (\(size.name))")
        } catch {
            alert("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecording(completion: (() -> Void)? = nil) {
        writerLock.lock()
        guard let finishedWriter = writer else {
            writerLock.unlock()
            completion?()
            return
        }
        let url = recordingURL
        let videoInput = writerVideoInput
        let audioInput = writerAudioInput
        let started = writerSessionStarted
        writer = nil
        writerVideoInput = nil
        writerAdaptor = nil
        writerAudioInput = nil
        writerSessionStarted = false
        recordingStart = nil
        recordingURL = nil
        writerLock.unlock()

        DispatchQueue.main.async {
            self.recordButton.title = "● Record"
            self.recordMenuItem.title = "Start Recording"
        }

        if started {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            finishedWriter.finishWriting {
                if finishedWriter.status == .completed, let url {
                    diag("Recording saved: \(url.path)")
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else if let error = finishedWriter.error as NSError? {
                    diag("Recording failed: \(error.domain) \(error.code) — \(error.localizedDescription); userInfo: \(error.userInfo)")
                } else {
                    diag("Recording failed: status \(finishedWriter.status.rawValue), no error object")
                }
                completion?()
            }
        } else {
            finishedWriter.cancelWriting()
            completion?()
        }
    }

    private func appendVideo(_ buffer: CVPixelBuffer, pts: CMTime) {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard let writer, let videoInput = writerVideoInput, let adaptor = writerAdaptor else { return }
        if !writerSessionStarted {
            guard writer.status == .unknown else { return }
            guard writer.startWriting() else {
                diag("startWriting failed: \((writer.error as NSError?)?.description ?? "?")")
                return
            }
            writer.startSession(atSourceTime: pts)
            writerSessionStarted = true
        }
        if writer.status == .writing, videoInput.isReadyForMoreMediaData {
            if !adaptor.append(buffer, withPresentationTime: pts) {
                diag("video append failed: \((writer.error as NSError?)?.description ?? "?")")
            }
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard writerSessionStarted, let writer, writer.status == .writing,
              let audioInput = writerAudioInput, audioInput.isReadyForMoreMediaData else { return }
        if !audioInput.append(sampleBuffer) {
            diag("audio append failed: \((writer.error as NSError?)?.description ?? "?")")
        }
    }

    // MARK: - Once-per-second UI refresh

    private func startUITimer() {
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            self.pollCursorForRail()

            // Blank the display instead of freezing on the last frame when frames stop.
            self.stateLock.lock()
            let sinceLastFrame = CFAbsoluteTimeGetCurrent() - self.lastFrameTime
            self.stateLock.unlock()
            if sinceLastFrame > 0.75 {
                if !self.displayBlanked {
                    self.displayBlanked = true
                    self.displayLayer.flushAndRemoveImage()
                    self.noSignalField.isHidden = false
                    diag("signal lost (frames stopped) — blanking display")
                }
            } else if self.displayBlanked {
                self.displayBlanked = false
                self.noSignalField.isHidden = true
                diag("signal restored")
            }

            self.uiTick += 1
            guard self.uiTick % 4 == 0 else { return }
            self.stateLock.lock()
            let fps = self.frameCount
            self.frameCount = 0
            let brightness = self.lastBrightness
            let adj = self.adjustments
            self.stateLock.unlock()

            self.writerLock.lock()
            let recStart = self.recordingStart
            let recURL = self.recordingURL
            self.writerLock.unlock()

            if let recStart {
                let secs = Int(Date().timeIntervalSince(recStart))
                self.recordButton.title = String(format: "■ %02d:%02d", secs / 60, secs % 60)
            }

            diag(String(format: "RipsawStats: frames=%d brightness=%.4f", fps, brightness))

            // Watchdog: a healthy session never goes a full 5s without frames.
            if fps == 0, self.videoDevice != nil, !self.reconfigurePending {
                self.zeroFrameSeconds += 1
                if self.zeroFrameSeconds >= 5 {
                    self.zeroFrameSeconds = 0
                    diag("watchdog: no frames for 5s — restarting capture session")
                    self.scheduleReconfigure(after: 0.1)
                }
            } else {
                self.zeroFrameSeconds = 0
            }

            guard !self.debugField.isHidden else { return }
            var lines: [String] = []
            if let device = self.videoDevice {
                let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let maxFPS = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                let fourCC = fourCCString(CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription))
                lines.append("device : \(device.localizedName)")
                lines.append(String(format: "input  : %d×%d @ %.2f fps [%@] → BGRA", dims.width, dims.height, maxFPS, fourCC))
            }
            let signal: String
            if fps == 0 { signal = "NO FRAMES" }
            else if brightness >= 0 && brightness < 0.02 { signal = "black (no signal / HDCP?)" }
            else { signal = "OK" }
            lines.append(String(format: "stream : %d fps, brightness %.0f%%, signal %@", fps, brightness * 100, signal))
            lines.append(String(format: "filter : B %+.2f  C %.2f  S %.2f  mirror %@  flip %@",
                                adj.brightness, adj.contrast, adj.saturation,
                                adj.mirrorH ? "ON" : "off", adj.flipV ? "ON" : "off"))
            if let recStart, let recURL {
                let secs = Int(Date().timeIntervalSince(recStart))
                let bytes = (try? FileManager.default.attributesOfItem(atPath: recURL.path)[.size] as? Int64) ?? nil
                let sizeText = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "0 B"
                let size = self.recordingSizes[max(0, self.sizePopup.indexOfSelectedItem)]
                lines.append(String(format: "record : ● %02d:%02d  %@ H.264  %@  %@",
                                    secs / 60, secs % 60, size.name, sizeText, recURL.lastPathComponent))
            } else {
                lines.append("record : idle → \((self.recordingsFolder.path as NSString).abbreviatingWithTildeInPath)/")
            }
            self.debugField.stringValue = lines.joined(separator: "\n")
        }
    }

    // MARK: - Alerts

    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = "Ripsaw HD Viewer"
        a.informativeText = message
        a.runModal()
    }

    private func fail(_ message: String) {
        alert(message)
        NSApp.terminate(nil)
    }
}

// MARK: - Helpers

let diagURL = URL(fileURLWithPath: NSHomeDirectory() + "/razer-ripsaw-hd/build/diag.log")
func diag(_ message: String) {
    NSLog("%@", message)
    let line = "\(Date()) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: diagURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: diagURL, atomically: true, encoding: .utf8)
    }
}

func fourCCString(_ code: FourCharCode) -> String {
    let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? String(code)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
