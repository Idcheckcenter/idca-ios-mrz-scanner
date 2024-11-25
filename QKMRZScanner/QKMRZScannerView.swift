//
//  QKMRZScannerView.swift
//  QKMRZScanner
//
//  Created by Matej Dorcak on 03/10/2018.
//

import UIKit
import AVFoundation
import SwiftyTesseract
import QKMRZParser
import AudioToolbox
import Vision
import os.log

// MARK: - QKMRZScannerViewDelegate
public protocol QKMRZScannerViewDelegate: AnyObject {
    func mrzScannerView(_ mrzScannerView: QKMRZScannerView, didFind scanResult: QKMRZScanResult)
}

// MARK: - QKMRZScannerView
@IBDesignable
public class QKMRZScannerView: UIView {
    fileprivate let tesseract = SwiftyTesseract(language: .custom("ocrb"), dataSource: Bundle(for: QKMRZScannerView.self), engineMode: .tesseractOnly)
    fileprivate let mrzParser = QKMRZParser(ocrCorrection: true)
    fileprivate let captureSession = AVCaptureSession()
    fileprivate let videoOutput = AVCaptureVideoDataOutput()
    fileprivate let videoPreviewLayer = AVCaptureVideoPreviewLayer()
    fileprivate let notificationFeedback = UINotificationFeedbackGenerator()
    fileprivate let cutoutView = QKCutoutView()
    fileprivate var isScanningPaused = false
    fileprivate var observer: NSKeyValueObservation?

    fileprivate var interfaceOrientation: UIInterfaceOrientation {
        return UIApplication.shared.statusBarOrientation
    }

    // MARK: Public properties
    @objc public dynamic var isScanning = false
    public var vibrateOnResult = true
    public weak var delegate: QKMRZScannerViewDelegate?

    public var cutoutRect: CGRect {
        return cutoutView.cutoutRect
    }

    // MRZ scan completion
    public var scanCompletion: (String, CGImage) -> Void = { mrzString, image in
        os_log("No completion handler set for scan - unable to stop scanning", log: OSLog.default, type: .debug)
    }

    // MARK: Initializers
    public init(scanCompletion: @escaping (String, CGImage) -> Void) {
        self.scanCompletion = scanCompletion
        self.init()
        initialize()
    }

    public init(frame: CGRect, scanCompletion: @escaping (String, CGImage) -> Void) {
        self.scanCompletion = scanCompletion
        super.init(frame: frame)
        initialize()
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        scanCompletion = completeScanIfValid
        initialize()
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        scanCompletion = completeScanIfValid
        initialize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Overriden methods
    override public func prepareForInterfaceBuilder() {
        setViewStyle()
        addCutoutView()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        adjustVideoPreviewLayerFrame()
    }

    // MARK: Scanning
    public func startScanning() {
        guard !captureSession.inputs.isEmpty else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            self?.notificationFeedback.prepare()
            DispatchQueue.main.async { [weak self] in self?.adjustVideoPreviewLayerFrame() }
        }
    }

    public func stopScanning() {
        captureSession.stopRunning()
    }

    // MARK: MRZ

    fileprivate func mrzString(from cgImage: CGImage) -> String? {
        let mrzTextImage = UIImage(cgImage: preprocessImage(cgImage))
        let recognizedString = try? tesseract.performOCR(on: mrzTextImage).get()

        if let string = recognizedString {
            return string
        }

        return nil
    }

    public func mrz(from mrzString: String?) -> QKMRZResult? {
        if let string = mrzString, let mrzLines = mrzLines(from: string) {
            return mrzParser.parse(mrzLines: mrzLines)
        }

        return nil
    }

    fileprivate func mrzLines(from recognizedText: String) -> [String]? {
        let mrzString = recognizedText.replacingOccurrences(of: " ", with: "")
        var mrzLines = mrzString.components(separatedBy: "\n").filter({ !$0.isEmpty })

        // Remove garbage strings located at the beginning and at the end of the result
        if !mrzLines.isEmpty {
            let averageLineLength = (mrzLines.reduce(0, { $0 + $1.count }) / mrzLines.count)
            mrzLines = mrzLines.filter({ $0.count >= averageLineLength })
        }

        return mrzLines.isEmpty ? nil : mrzLines
    }

    // MARK: Document Image from Photo cropping
    fileprivate func cutoutRect(for cgImage: CGImage) -> CGRect {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let rect = videoPreviewLayer.metadataOutputRectConverted(fromLayerRect: cutoutRect)
        let videoOrientation = videoPreviewLayer.connection!.videoOrientation

        if videoOrientation == .portrait || videoOrientation == .portraitUpsideDown {
            return CGRect(x: (rect.minY * imageWidth), y: (rect.minX * imageHeight), width: (rect.height * imageWidth), height: (rect.width * imageHeight))
        }
        else {
            return CGRect(x: (rect.minX * imageWidth), y: (rect.minY * imageHeight), width: (rect.width * imageWidth), height: (rect.height * imageHeight))
        }
    }

    fileprivate func documentImage(from cgImage: CGImage) -> CGImage {
        let croppingRect = cutoutRect(for: cgImage)
        return cgImage.cropping(to: croppingRect) ?? cgImage
    }

    fileprivate func enlargedDocumentImage(from cgImage: CGImage) -> UIImage {
        var croppingRect = cutoutRect(for: cgImage)
        let margin = (0.05 * croppingRect.height) // 5% of the height
        croppingRect = CGRect(x: (croppingRect.minX - margin), y: (croppingRect.minY - margin), width: croppingRect.width + (margin * 2), height: croppingRect.height + (margin * 2))
        return UIImage(cgImage: cgImage.cropping(to: croppingRect)!)
    }

    // MARK: UIApplication Observers
    @objc fileprivate func appWillEnterForeground() {
        if isScanningPaused {
            isScanningPaused = false
            startScanning()
        }
    }

    @objc fileprivate func appDidEnterBackground() {
        if isScanning {
            isScanningPaused = true
            stopScanning()
        }
    }

    // MARK: Init methods
    fileprivate func initialize() {
        FilterVendor.registerFilters()
        setViewStyle()
        addCutoutView()
        initCaptureSession()
        addAppObservers()
    }

    fileprivate func setViewStyle() {
        backgroundColor = .black
    }

    fileprivate func addCutoutView() {
        cutoutView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cutoutView)

        NSLayoutConstraint.activate([
            cutoutView.topAnchor.constraint(equalTo: topAnchor),
            cutoutView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cutoutView.leftAnchor.constraint(equalTo: leftAnchor),
            cutoutView.rightAnchor.constraint(equalTo: rightAnchor)
        ])
    }

    fileprivate static var identifier: String = {
      var systemInfo = utsname()
      uname(&systemInfo)
      let mirror = Mirror(reflecting: systemInfo.machine)

      let identifier = mirror.children.reduce("") { identifier, element in
        guard let value = element.value as? Int8, value != 0 else { return identifier }
        return identifier + String(UnicodeScalar(UInt8(value)))
      }
      return identifier
    }()
    
    static func getCamera() -> AVCaptureDevice? {
        var deviceTypes: [AVCaptureDevice.DeviceType] = Array()
        if #available(iOS 13.0, *) {
            let identifier = identifier
            if (identifier == "iPhone15,2" || identifier == "iPhone15,3"
                || identifier == "iPhone16,1" || identifier == "iPhone16,2"
                || identifier == "iPhone17,1" || identifier == "iPhone17,2") {
                deviceTypes.append(.builtInTripleCamera)
                deviceTypes.append(.builtInDualWideCamera)
            }
        }
        deviceTypes.append(.builtInWideAngleCamera)

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: AVMediaType.video,
            position: .back)

        if #available(iOS 13.0, *) {
            for device in discoverySession.devices where device.deviceType == .builtInTripleCamera {
                return device
            }
            
            for device in discoverySession.devices where device.deviceType == .builtInDualWideCamera {
                return device
            }
        }

        for device in discoverySession.devices where device.deviceType == .builtInWideAngleCamera {
            return device
        }

        return nil
    }

    fileprivate func initCaptureSession() {
        captureSession.sessionPreset = .hd1920x1080

        guard let camera = QKMRZScannerView.getCamera() else {
            print("Camera not accessible")
            return
        }

        guard let deviceInput = try? AVCaptureDeviceInput(device: camera) else {
            print("Capture input could not be initialized")
            return
        }

        observer = captureSession.observe(\.isRunning, options: [.new]) { [unowned self] (model, change) in
            // CaptureSession is started from the global queue (background). Change the `isScanning` on the main
            // queue to avoid triggering the change handler also from the global queue as it may affect the UI.
            DispatchQueue.main.async { [weak self] in self?.isScanning = change.newValue! }
        }

        if captureSession.canAddInput(deviceInput) && captureSession.canAddOutput(videoOutput) {
            captureSession.addInput(deviceInput)
            captureSession.addOutput(videoOutput)

            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "video_frames_queue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem))
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as [String : Any]
            videoOutput.connection(with: .video)!.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)

            videoPreviewLayer.session = captureSession
            videoPreviewLayer.videoGravity = .resizeAspectFill

            layer.insertSublayer(videoPreviewLayer, at: 0)
        }
        else {
            print("Input & Output could not be added to the session")
        }
    }

    fileprivate func addAppObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: Misc
    fileprivate func adjustVideoPreviewLayerFrame() {
        videoOutput.connection(with: .video)?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.connection?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.frame = bounds
    }

    fileprivate func preprocessImage(_ image: CGImage) -> CGImage {
        var inputImage = CIImage(cgImage: image)
        let averageLuminance = inputImage.averageLuminance
        var exposure = 0.5
        let threshold = (1 - pow(1 - averageLuminance, 0.2))

        if averageLuminance > 0.8 {
            exposure -= ((averageLuminance - 0.5) * 2)
        }

        if averageLuminance < 0.35 {
            exposure += pow(2, (0.5 - averageLuminance))
        }

        inputImage = inputImage.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure])
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 2])
            .applyingFilter("LuminanceThresholdFilter", parameters: ["inputThreshold": threshold])

        return CIContext.shared.createCGImage(inputImage, from: inputImage.extent)!
    }

    /// Default implementation to complete a scan if the result is valid based on check digits.
    /// Set in init and used if no custom scanCompletion handler is passed in
    /// - Warning: This method may fail, if a MRZ is scanned correctly but does not conform to the ISO standard (for example german ID cards)!
    /// - Parameter mrz: The mrz string as recognized by tesseract
    /// - Parameter cgImage: The image used for tesseract / ocr
    private func completeScanIfValid(mrz: String, cgImage: CGImage) {
        guard let mrzResult = self.mrz(from: mrz) else {
            return
        }

        if mrzResult.allCheckDigitsValid {
            self.stopScanning()
            DispatchQueue.main.async {
                let enlargedDocumentImage = self.enlargedDocumentImage(from: cgImage)
                let scanResult = QKMRZScanResult(mrzResult: mrzResult, documentImage: enlargedDocumentImage)
                self.delegate?.mrzScannerView(self, didFind: scanResult)
                if self.vibrateOnResult {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                }
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension QKMRZScannerView: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let cgImage = CMSampleBufferGetImageBuffer(sampleBuffer)?.cgImage else {
            return
        }

        let documentImage = self.documentImage(from: cgImage)
        let imageRequestHandler = VNImageRequestHandler(cgImage: documentImage, options: [:])

        let detectTextRectangles = VNDetectTextRectanglesRequest { [unowned self] request, error in
            guard error == nil else {
                return
            }

            guard let results = request.results as? [VNTextObservation] else {
                return
            }

            let imageWidth = CGFloat(documentImage.width)
            let imageHeight = CGFloat(documentImage.height)
            let transform = CGAffineTransform.identity.scaledBy(x: imageWidth, y: -imageHeight).translatedBy(x: 0, y: -1)
            let mrzTextRectangles = results.map({ $0.boundingBox.applying(transform) }).filter({ $0.width > (imageWidth * 0.8) })
            let mrzRegionRect = mrzTextRectangles.reduce(into: CGRect.null, { $0 = $0.union($1) })

            guard mrzRegionRect.height <= (imageHeight * 0.4) else { // Avoid processing the full image (can occur if there is a long text in the header)
                return
            }

            if let mrzTextImage = documentImage.cropping(to: mrzRegionRect) {
                if let mrzString = self.mrzString(from: mrzTextImage) {
                    scanCompletion(mrzString, mrzTextImage)
                }
            }
        }

        try? imageRequestHandler.perform([detectTextRectangles])
    }
}
