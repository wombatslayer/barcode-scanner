import Capacitor
import Foundation
import AVFoundation

@objc(BarcodeScanner)
public class BarcodeScanner: CAPPlugin, AVCaptureMetadataOutputObjectsDelegate {

    class CameraView: UIView {
        var videoPreviewLayer:AVCaptureVideoPreviewLayer?

        func interfaceOrientationToVideoOrientation(_ orientation : UIInterfaceOrientation) -> AVCaptureVideoOrientation {
            switch (orientation) {
            case UIInterfaceOrientation.portrait:
                return AVCaptureVideoOrientation.portrait
            case UIInterfaceOrientation.portraitUpsideDown:
                return AVCaptureVideoOrientation.portraitUpsideDown
            case UIInterfaceOrientation.landscapeLeft:
                return AVCaptureVideoOrientation.landscapeLeft
            case UIInterfaceOrientation.landscapeRight:
                return AVCaptureVideoOrientation.landscapeRight
            default:
                return AVCaptureVideoOrientation.portraitUpsideDown
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let sublayers = self.layer.sublayers {
                for layer in sublayers {
                    layer.frame = self.bounds
                }
            }

            self.videoPreviewLayer?.connection?.videoOrientation = interfaceOrientationToVideoOrientation(UIApplication.shared.statusBarOrientation)
        }


        func addPreviewLayer(_ previewLayer:AVCaptureVideoPreviewLayer?) {
            previewLayer!.videoGravity = AVLayerVideoGravity.resizeAspectFill
            previewLayer!.frame = self.bounds
            self.layer.addSublayer(previewLayer!)
            self.videoPreviewLayer = previewLayer
        }

        func removePreviewLayer() {
            if self.videoPreviewLayer != nil {
                self.videoPreviewLayer!.removeFromSuperlayer()
                self.videoPreviewLayer = nil
            }
        }
    }

    var cameraView: CameraView!
    var captureSession:AVCaptureSession?
    var captureVideoPreviewLayer:AVCaptureVideoPreviewLayer?
    var metaOutput: AVCaptureMetadataOutput?

    var currentCamera: Int = 0
    var frontCamera: AVCaptureDevice?
    var backCamera: AVCaptureDevice?

    var isScanning: Bool = false
    var shouldRunScan: Bool = false
    var didRunCameraSetup: Bool = false
    var didRunCameraPrepare: Bool = false
    var isBackgroundHidden: Bool = false

    var savedCall: CAPPluginCall? = nil
    var scanningPaused: Bool = false
    var lastScanResult: String? = nil

    enum SupportedFormat: String, CaseIterable {
        // 1D Product
        //!\ UPC_A is part of EAN_13 according to Apple docs
        case UPC_E
        //!\ UPC_EAN_EXTENSION is not supported by AVFoundation
        case EAN_8
        case EAN_13
        // 1D Industrial
        case CODE_39
        case CODE_39_MOD_43
        case CODE_93
        case CODE_128
        //!\ CODABAR is not supported by AVFoundation
        case ITF
        case ITF_14
        // 2D
        case AZTEC
        case DATA_MATRIX
        //!\ MAXICODE is not supported by AVFoundation
        case PDF_417
        case QR_CODE
        //!\ RSS_14 is not supported by AVFoundation
        //!\ RSS_EXPANDED is not supported by AVFoundation

        var value: AVMetadataObject.ObjectType {
            switch self {
                // 1D Product
                case .UPC_E: return AVMetadataObject.ObjectType.upce
                case .EAN_8: return AVMetadataObject.ObjectType.ean8
                case .EAN_13: return AVMetadataObject.ObjectType.ean13
                // 1D Industrial
                case .CODE_39: return AVMetadataObject.ObjectType.code39
                case .CODE_39_MOD_43: return AVMetadataObject.ObjectType.code39Mod43
                case .CODE_93: return AVMetadataObject.ObjectType.code93
                case .CODE_128: return AVMetadataObject.ObjectType.code128
                case .ITF: return AVMetadataObject.ObjectType.interleaved2of5
                case .ITF_14: return AVMetadataObject.ObjectType.itf14
                // 2D
                case .AZTEC: return AVMetadataObject.ObjectType.aztec
                case .DATA_MATRIX: return AVMetadataObject.ObjectType.dataMatrix
                case .PDF_417: return AVMetadataObject.ObjectType.pdf417
                case .QR_CODE: return AVMetadataObject.ObjectType.qr
            }
        }
    }

    var targetedFormats = [AVMetadataObject.ObjectType]()

    enum CaptureError: Error {
        case backCameraUnavailable
        case frontCameraUnavailable
        case couldNotCaptureInput(error: NSError)
    }

    public override func load() {
        self.cameraView = CameraView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
        self.cameraView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    private func hasCameraPermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
        if (status == AVAuthorizationStatus.authorized) {
            return true
        }
        return false
    }

    private func setupCamera(cameraDirection: String? = "back") -> Bool {
        do {
            var cameraDir = cameraDirection
            cameraView.backgroundColor = UIColor.clear
            self.webView!.superview!.insertSubview(cameraView, belowSubview: self.webView!)
            
            let availableVideoDevices =  discoverCaptureDevices()
            for device in availableVideoDevices {
                if device.position == AVCaptureDevice.Position.back {
                    backCamera = device
                }
                else if device.position == AVCaptureDevice.Position.front {
                    frontCamera = device
                }
            }
            // older iPods have no back camera
            if (cameraDir == "back") {
                if (backCamera == nil) {
                    cameraDir = "front"
                }
            } else {
                if (frontCamera == nil) {
                    cameraDir = "back"
                }
            }
            let input: AVCaptureDeviceInput
            input = try self.createCaptureDeviceInput(cameraDirection: cameraDir)
            captureSession = AVCaptureSession()
            captureSession!.addInput(input)
            metaOutput = AVCaptureMetadataOutput()
            captureSession!.addOutput(metaOutput!)
            metaOutput!.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            captureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession!)
            cameraView.addPreviewLayer(captureVideoPreviewLayer)
            self.didRunCameraSetup = true
            return true
        } catch CaptureError.backCameraUnavailable {
            //
        } catch CaptureError.frontCameraUnavailable {
            //
        } catch CaptureError.couldNotCaptureInput {
            //
        } catch {
            //
        }
        return false
    }

    @available(swift, deprecated: 5.6, message: "New Xcode? Check if `AVCaptureDevice.DeviceType` has new types and add them accordingly.")
    private func discoverCaptureDevices() -> [AVCaptureDevice] {
        if #available(iOS 13.0, *) {
            return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera, .builtInUltraWideCamera, .builtInDualWideCamera, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        } else {
            return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualCamera, .builtInWideAngleCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified).devices
        }
    }

    private func createCaptureDeviceInput(cameraDirection: String? = "back") throws -> AVCaptureDeviceInput {
        var captureDevice: AVCaptureDevice
        if(cameraDirection == "back"){
            if(backCamera != nil){
                captureDevice = backCamera!
            } else {
                throw CaptureError.backCameraUnavailable
            }
        } else {
            if(frontCamera != nil){
                captureDevice = frontCamera!
            } else {
                throw CaptureError.frontCameraUnavailable
            }
        }
        let captureDeviceInput: AVCaptureDeviceInput
        do {
            captureDeviceInput = try AVCaptureDeviceInput(device: captureDevice)
        } catch let error as NSError {
            throw CaptureError.couldNotCaptureInput(error: error)
        }
        return captureDeviceInput
    }

    private func dismantleCamera() {
        // opposite of setupCamera

        if (self.captureSession != nil) {
            DispatchQueue.main.async {
                self.captureSession!.stopRunning()
                self.cameraView.removePreviewLayer()
                self.captureVideoPreviewLayer = nil
                self.metaOutput = nil
                self.captureSession = nil
                self.frontCamera = nil
                self.backCamera = nil
            }
        }

        self.isScanning = false
        self.didRunCameraSetup = false
        self.didRunCameraPrepare = false

        // If a call is saved and a scan will not run, free the saved call
        if (self.savedCall != nil && !self.shouldRunScan) {
            self.savedCall = nil
        }
    }

    private func prepare(_ call: CAPPluginCall? = nil) {
        // undo previous setup
        // because it may be prepared with a different config
        self.dismantleCamera()

        DispatchQueue.main.async {
            // setup camera with new config
            if (self.setupCamera(cameraDirection: call?.getString("cameraDirection") ?? "back")) {
                // indicate this method was run
                self.didRunCameraPrepare = true

                if (self.shouldRunScan) {
                    self.scan()
                }
            } else {
                self.shouldRunScan = false
            }
        }
    }

    private func destroy() {
        self.showBackground()

        self.dismantleCamera()
    }

    private func scan() {
        if (!self.didRunCameraPrepare) {
            //In iOS 14 don't identify permissions needed, so force to ask it's better than nothing. Provisional.
            var iOS14min: Bool = false
            if #available(iOS 14.0, *) { iOS14min = true; }
            if (!self.hasCameraPermission() && !iOS14min) {
                // @TODO()
                // requestPermission()
            } else {
                DispatchQueue.main.async {
                    self.load();
                    self.shouldRunScan = true
                    self.prepare(self.savedCall)
                } 
            }
        } else {
            self.didRunCameraPrepare = false

            self.shouldRunScan = false

            targetedFormats = [AVMetadataObject.ObjectType]();

            if ((savedCall?.options["targetedFormats"]) != nil) {
                let _targetedFormats = savedCall?.getArray("targetedFormats", String.self)

                if (_targetedFormats != nil && _targetedFormats?.count ?? 0 > 0) {
                    _targetedFormats?.forEach { targetedFormat in
                        if let value = SupportedFormat(rawValue: targetedFormat)?.value {
                            print(value)
                            targetedFormats.append(value)
                        }
                    }
                }

                if (targetedFormats.count == 0) {
                    print("The property targetedFormats was not set correctly.")
                }
            }

            if (targetedFormats.count == 0) {
                for supportedFormat in SupportedFormat.allCases {
                    targetedFormats.append(supportedFormat.value)
                }
            }

            DispatchQueue.main.async {
                self.metaOutput!.metadataObjectTypes = self.targetedFormats
                self.captureSession!.startRunning()
            }

            self.hideBackground()

            self.isScanning = true
        }
    }

    private func hideBackground() {
        DispatchQueue.main.async {
            self.bridge?.webView!.isOpaque = false
            self.bridge?.webView!.backgroundColor = UIColor.clear
            self.bridge?.webView!.scrollView.backgroundColor = UIColor.clear

            let javascript = "document.documentElement.style.backgroundColor = 'transparent'"

            self.bridge?.webView!.evaluateJavaScript(javascript)
        }
    }

    private let supportedModes: [Mode] = [.structuredAppend, .byte, .endOfMessage]

    private func decode(_ binary: inout Binary, stringVal: inout String, symbolVersion: Int) {
        let modeBitsLength = 4
        guard binary.bitsWithInternalOffsetAvailable(modeBitsLength) else { return }

        let modeBits = binary.next(bits: modeBitsLength)
        guard let mode = Mode(rawValue: modeBits),
            supportedModes.contains(mode) else {
            print("Error")
            return
        }

        print(mode.description)
        guard mode != .endOfMessage else { return }

        if case .structuredAppend = mode {
            let symbolPosition = binary.next(bits: 4)
            let totalSymbols = binary.next(bits: 4)
            let parity = binary.next(bits: 8)
            print("Total: \(totalSymbols + 1), Position: \(symbolPosition + 1). Parity: \(parity).\n\n")
        } else if case .byte = mode {
            guard let numberOfBitsInLengthFiled = mode.numberOfBitsInLengthFiled(for: symbolVersion),
                let numberOfBitsPerCharacter = mode.numberOfBitsPerCharacter else { return }
            let totalCharacterCount = binary.next(bits: numberOfBitsInLengthFiled)
            var bytes: [UInt8] = []
            for _ in 0..<totalCharacterCount {
                let byte = binary.next(bits: numberOfBitsPerCharacter)
                bytes.append(UInt8(byte))
            }
            let binAsData = Data(bytes)
            
            stringVal = stringVal + binAsData.base64EncodedString()
            print(stringVal)
        }

        decode(&binary, stringVal: &stringVal, symbolVersion: symbolVersion)
    }

    private func decodeQRErrorCorrectedBytesToB64(errorCorrectedPayload: Data, symbolVersion: Int) -> String {
        var binData = Binary(data: errorCorrectedPayload)
        var decodedString = ""
        decode(&binData, stringVal: &decodedString, symbolVersion: symbolVersion)
        return decodedString
    }

    private func showBackground() {
        DispatchQueue.main.async {
            let javascript = "document.documentElement.style.backgroundColor = ''"

            self.bridge?.webView!.evaluateJavaScript(javascript) { (result, error) in
                self.bridge?.webView!.isOpaque = true
                self.bridge?.webView!.backgroundColor = UIColor.white
                self.bridge?.webView!.scrollView.backgroundColor = UIColor.white
            }
        }
    }

    // This method processes metadataObjects captured by iOS.
    public func metadataOutput(_ captureOutput: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {

        if (metadataObjects.count == 0 || !self.isScanning) {
            // while nothing is detected, or if scanning is false, do nothing.
            return
        }

        let found = metadataObjects[0] as! AVMetadataMachineReadableCodeObject
        if (targetedFormats.contains(found.type)) {
            var jsObject = PluginCallResultData()

            if (found.type == AVMetadataObject.ObjectType.qr){
                let qrCodeDescriptor = found.descriptor as? CIQRCodeDescriptor
                
                // if string value is nil, either there is nothing there, or it was not encoded correctly
                if (found.stringValue == nil) {
                    if let rawBytes = qrCodeDescriptor?.errorCorrectedPayload {
                        //raw bytes needs to be processed to get the actual qr code message
                        let symbolVersion = qrCodeDescriptor?.symbolVersion
                        jsObject["hasContent"] = true
                        jsObject["content"] = self.decodeQRErrorCorrectedBytesToB64(errorCorrectedPayload: rawBytes, symbolVersion: symbolVersion!)
                        jsObject["format"] = formatStringFromMetadata(found.type)
                    } else {
                        jsObject["hasContent"] = false
                    }
                } else {
                    // if string value is not nil, then use it
                    jsObject["hasContent"] = true
                    jsObject["content"] = found.stringValue
                    jsObject["format"] = formatStringFromMetadata(found.type)
                }
            } else {    
                // not a QR code
                if (found.stringValue != nil) {
                    jsObject["hasContent"] = true
                    jsObject["content"] = found.stringValue
                    jsObject["format"] = formatStringFromMetadata(found.type)
                } else {
                    jsObject["hasContent"] = false
                }
            }

            if (savedCall != nil) {
                if (savedCall!.keepAlive) {
                    if (!scanningPaused && found.stringValue != lastScanResult ) {
                        lastScanResult = found.stringValue
                        savedCall!.resolve(jsObject)
                    }
                } else {
                    savedCall!.resolve(jsObject)
                    savedCall = nil
                    destroy()
                }
            } else {
                self.destroy()
            }
        }
    }

    private func formatStringFromMetadata(_ type: AVMetadataObject.ObjectType) -> String {
            switch type {
            case AVMetadataObject.ObjectType.upce:
                return "UPC_E"
            case AVMetadataObject.ObjectType.ean8:
                return "EAN_8"
            case AVMetadataObject.ObjectType.ean13:
                return "EAN_13"
            case AVMetadataObject.ObjectType.code39:
                return "CODE_39"
            case AVMetadataObject.ObjectType.code39Mod43:
                return "CODE_39_MOD_43"
            case AVMetadataObject.ObjectType.code93:
                return "CODE_93"
            case AVMetadataObject.ObjectType.code128:
                return "CODE_128"
            case AVMetadataObject.ObjectType.interleaved2of5:
                return "ITF"
            case AVMetadataObject.ObjectType.itf14:
                return "ITF_14"
            case AVMetadataObject.ObjectType.aztec:
                return "AZTEC"
            case AVMetadataObject.ObjectType.dataMatrix:
                return "DATA_MATRIX"
            case AVMetadataObject.ObjectType.pdf417:
                return "PDF_417"
            case AVMetadataObject.ObjectType.qr:
                return "QR_CODE"
            default:
                return type.rawValue
            }
        }

    @objc func prepare(_ call: CAPPluginCall) {
        self.prepare()
        call.resolve()
    }

    @objc func hideBackground(_ call: CAPPluginCall) {
        self.hideBackground()
        call.resolve()
    }

    @objc func showBackground(_ call: CAPPluginCall) {
        self.showBackground()
        call.resolve()
    }

    @objc func startScan(_ call: CAPPluginCall) {
        self.savedCall = call
        self.scan()
    }

    @objc func startScanning(_ call: CAPPluginCall) {
        self.savedCall = call
        self.savedCall?.keepAlive = true
        scanningPaused = false
        lastScanResult = nil
        self.scan()
    }

    @objc func pauseScanning(_ call: CAPPluginCall) {
        scanningPaused = true
        call.resolve()
    }

    @objc func resumeScanning(_ call: CAPPluginCall) {
       lastScanResult = nil
        scanningPaused = false
        call.resolve()
    }

    @objc func stopScan(_ call: CAPPluginCall) {
        if ((call.getBool("resolveScan") ?? false) && self.savedCall != nil) {
            var jsObject = PluginCallResultData()
            jsObject["hasContent"] = false

            savedCall?.resolve(jsObject)
            savedCall = nil
        }

        self.destroy()
        call.resolve()
    }

    @objc func checkPermission(_ call: CAPPluginCall) {
        let force = call.getBool("force") ?? false

        var savedReturnObject = PluginCallResultData()

        DispatchQueue.main.async {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    savedReturnObject["granted"] = true
                case .denied:
                    savedReturnObject["denied"] = true
                case .notDetermined:
                    savedReturnObject["neverAsked"] = true
                case .restricted:
                    savedReturnObject["restricted"] = true
                @unknown default:
                    savedReturnObject["unknown"] = true
            }

            if (force && savedReturnObject["neverAsked"] != nil) {
                savedReturnObject["asked"] = true

                AVCaptureDevice.requestAccess(for: .video) { (authorized) in
                    if (authorized) {
                        savedReturnObject["granted"] = true
                    } else {
                        savedReturnObject["denied"] = true
                    }
                    call.resolve(savedReturnObject)
                }
            } else {
                call.resolve(savedReturnObject)
            }
        }
    }

    @objc func openAppSettings(_ call: CAPPluginCall) {
      guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
          return
      }

      DispatchQueue.main.async {
          if UIApplication.shared.canOpenURL(settingsUrl) {
              UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                  call.resolve()
              })
          }
      }
    }

      @objc func enableTorch(_ call: CAPPluginCall) {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video) else { return }
        guard device.hasTorch else { return }
        guard device.isTorchAvailable else { return }

        do {
            try device.lockForConfiguration()

            do {
                try device.setTorchModeOn(level: 1.0)
            } catch {
                print(error)
            }

            device.unlockForConfiguration()
        } catch {
            print(error)
        }

        call.resolve()
    }

    @objc func disableTorch(_ call: CAPPluginCall) {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video) else { return }
        guard device.hasTorch else { return }
        guard device.isTorchAvailable else { return }

        do {
            try device.lockForConfiguration()
            device.torchMode = .off

            device.unlockForConfiguration()
        } catch {
            print(error)
        }

        call.resolve()
    }

    @objc func toggleTorch(_ call: CAPPluginCall) {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video) else { return }
        guard device.hasTorch else { return }
        guard device.isTorchAvailable else { return }

        if (device.torchMode == .on) {
            self.disableTorch(call)
        } else {
            self.enableTorch(call)
        }
    }

    @objc func getTorchState(_ call: CAPPluginCall) {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video) else { return }

        var result = PluginCallResultData()

        result["isEnabled"] = device.torchMode == .on

        call.resolve(result)
    }

}


public struct Binary {
    public let bytes: [UInt8]
    public var readingOffset: Int = 0

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(data: Data) {
        let bytesLength = data.count
        var bytesArray  = [UInt8](repeating: 0, count: bytesLength)
        (data as NSData).getBytes(&bytesArray, length: bytesLength)
        self.bytes      = bytesArray
    }

    public func bit(_ position: Int) -> Int {
        let byteSize        = 8
        let bytePosition    = position / byteSize
        let bitPosition     = 7 - (position % byteSize)
        let byte            = self.byte(bytePosition)
        return (byte >> bitPosition) & 0x01
    }

    public func bits(_ range: Range<Int>) -> Int {
        var positions = [Int]()

        for position in range.lowerBound..<range.upperBound {
            positions.append(position)
        }

        return positions.reversed().enumerated().reduce(0) {
            $0 + (bit($1.element) << $1.offset)
        }
    }

    public func bits(_ start: Int, _ length: Int) -> Int {
        return self.bits(start..<(start + length))
    }

    public func byte(_ position: Int) -> Int {
        return Int(self.bytes[position])
    }

    public func bytes(_ start: Int, _ length: Int) -> [UInt8] {
        return Array(self.bytes[start..<start+length])
    }

    public func bytes(_ start: Int, _ length: Int) -> Int {
        return bits(start*8, length*8)
    }

    public func bitsWithInternalOffsetAvailable(_ length: Int) -> Bool {
        return (self.bytes.count * 8) >= (self.readingOffset + length)
    }

    public mutating func next(bits length: Int) -> Int {
        if self.bitsWithInternalOffsetAvailable(length) {
            let returnValue = self.bits(self.readingOffset, length)
            self.readingOffset = self.readingOffset + length
            return returnValue
        } else {
            fatalError("Couldn't extract Bits.")
        }
    }

    public func bytesWithInternalOffsetAvailable(_ length: Int) -> Bool {
        let availableBits = self.bytes.count * 8
        let requestedBits = readingOffset + (length * 8)
        let possible      = availableBits >= requestedBits
        return possible
    }

    public mutating func next(bytes length: Int) -> [UInt8] {
        if bytesWithInternalOffsetAvailable(length) {
            let returnValue = self.bytes[(self.readingOffset / 8)..<((self.readingOffset / 8) + length)]
            self.readingOffset = self.readingOffset + (length * 8)
            return Array(returnValue)
        } else {
            fatalError("Couldn't extract Bytes.")
        }
    }
}

enum SymbolType {
    case small
    case medium
    case large

    init?(version: Int) {
        if 1 <= version, version <= 9 {
            self = .small
        } else if 10 <= version, version <= 26 {
            self = .medium
        } else if 27 <= version, version <= 40 {
            self = .large
        } else {
            return nil
        }
    }
}

enum Mode: Int {
    case numeric              = 1 // 0001 数字
    case alphanumeric         = 2 // 0010 英数字
    case byte                 = 4 // 0100 バイト
    case kanji                = 8 // 1000 漢字
    case structuredAppend     = 3 // 0011 構造的連接
    case eci                  = 7 // 0111 ECI
    case fnc1InFirstPosition  = 5 // 0101 FNC1（1番目の位置）
    case fnc1InSecondPosition = 9 // 1001 FNC1（1番目の位置）
    case endOfMessage         = 0 // 0000 終端パターン
    var description: String {
        switch self {
        case .numeric:              return "0001 numeric"
        case .alphanumeric:         return "0010 alphanumeric"
        case .byte:                 return "0100 byte"
        case .kanji:                return "1000 kanji"
        case .structuredAppend:     return "0011 structuredAppend"
        case .eci:                  return "0111 ECI"
        case .fnc1InFirstPosition:  return "0101 FNC1 1st pos"
        case .fnc1InSecondPosition: return "1001 FNC1 2nd pos"
        case .endOfMessage:         return "0000 end of message"
        }
    }

    var hasNumberOfBitsInLengthFiled: Bool {
        switch self {
        case .numeric, .alphanumeric, .byte, .kanji:
            return true
        default:
            return false
        }
    }

    var numberOfBitsPerCharacter: Int? {
        switch self {
        case .numeric: return 10
        case .alphanumeric: return 11
        case .byte: return 8
        case .kanji: return 13
        default: return nil
        }
    }

    func numberOfBitsInLengthFiled(for symbolVersion: Int) -> Int? {
        guard let symbolType = SymbolType(version: symbolVersion) else { return nil }
        switch self {
        case .numeric:
            switch symbolType {
            case .small: return 10
            case .medium: return 12
            case .large: return 14
            }

        case .alphanumeric:
            switch symbolType {
            case .small: return 9
            case .medium: return 11
            case .large: return 13
            }

        case .byte:
            switch symbolType {
            case .small: return 8
            case .medium: return 16
            case .large: return 16
            }

        case .kanji:
            switch symbolType {
            case .small: return 8
            case .medium: return 10
            case .large: return 12
            }

        default:
            return nil
        }
    }
}
