//
//  ViewController.swift
//  VisionCreditScan
//
//  Created by Anupam Chugh on 27/01/20.
//  Copyright © 2020 iowncode. All rights reserved.
//

import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController {
    
    private let captureSession = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()

    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    
    var textRecognitionRequest = VNRecognizeTextRequest(completionHandler: nil)
    private let textRecognitionWorkQueue = DispatchQueue(label: "MyVisionScannerQueue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    
    private var readyToParseNewData = true
    private var maskLayer = CAShapeLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupVision()
        setCameraInput()
        showCameraFeed()
        setCameraOutput()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera_frame_processing_queue"))
        captureSession.startRunning()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
        captureSession.stopRunning()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.frame
    }
    
    private func setupVision() {
        textRecognitionRequest = VNRecognizeTextRequest { [weak self] (request, error) in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                self?.readyToParseNewData = true
                return
            }
            
            var cardNumber: String?
            var expiryDate: String?
            
            observations.forEach { observation in
                guard let topCandidate = observation.topCandidates(1).first, topCandidate.confidence == 1 else {
                    return
                }
                
                if topCandidate.string.isCardNumber {
                    cardNumber = topCandidate.string
                }
                
                if topCandidate.string.isCardExpiryDate {
                    expiryDate = topCandidate.string
                }
            }
            
            guard let number = cardNumber, let date = expiryDate else {
                self?.readyToParseNewData = true
                return
            }
        
            let detectedInfo = ["Card Number: \(number)", "Expiry Date: \(date)"].joined(separator: "\n")
            
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "Detected data", message: detectedInfo, preferredStyle: .alert)
                
                alert.addAction(
                    UIAlertAction(title: "OK", style: .cancel) { _ in
                        self?.readyToParseNewData = true
                    }
                )
                
                self?.present(alert, animated: true, completion: nil)
            }
        }

        textRecognitionRequest.recognitionLevel = .accurate
    }
    
    private func setCameraInput() {
        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .back
        ).devices.first else {
            fatalError("No back camera device found.")
        }
        
        let cameraInput = try! AVCaptureDeviceInput(device: device)
        captureSession.addInput(cameraInput)
    }
    
    private func showCameraFeed() {
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        previewLayer.frame = view.frame
    }
    
    private func setCameraOutput() {
        videoDataOutput.videoSettings = [
            (kCVPixelBufferPixelFormatTypeKey as NSString) : NSNumber(value: kCVPixelFormatType_32BGRA)
        ] as [String : Any]
        
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera_frame_processing_queue"))
        
        captureSession.addOutput(videoDataOutput)
        
        guard let connection = videoDataOutput.connection(with: AVMediaType.video),
            connection.isVideoOrientationSupported else {
            return
        }
        
        connection.videoOrientation = .portrait
    }
    
    private func detectRectangle(in image: CVPixelBuffer) {
        let request = VNDetectRectanglesRequest { (request: VNRequest, error: Error?) in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let results = request.results as? [VNRectangleObservation] else {
                    return
                }
                
                self.removeMask()
                
                guard let rect = results.first else {
                    return
                }
                
                self.drawBoundingBox(rect: rect)
                self.doPerspectiveCorrection(rect, from: image)
            }
        }
        
        request.minimumAspectRatio = VNAspectRatio(1.3)
        request.maximumAspectRatio = VNAspectRatio(1.8)
        request.minimumSize = 0.4
        request.maximumObservations = 1
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: image, options: [:])
        try? imageRequestHandler.perform([request])
    }
    
    private func drawBoundingBox(rect : VNRectangleObservation) {
        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -self.previewLayer.frame.height)
        let scale = CGAffineTransform.identity.scaledBy(x: self.previewLayer.frame.width, y: self.previewLayer.frame.height)

        let bounds = rect.boundingBox.applying(scale).applying(transform)
        createLayer(in: bounds)
    }
    
    private func doPerspectiveCorrection(_ observation: VNRectangleObservation, from buffer: CVImageBuffer) {
        var ciImage = CIImage(cvImageBuffer: buffer)

        let topLeft = observation.topLeft.scaled(to: ciImage.extent.size)
        let topRight = observation.topRight.scaled(to: ciImage.extent.size)
        let bottomLeft = observation.bottomLeft.scaled(to: ciImage.extent.size)
        let bottomRight = observation.bottomRight.scaled(to: ciImage.extent.size)

        // pass those to the filter to extract/rectify the image
        ciImage = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: topLeft),
            "inputTopRight": CIVector(cgPoint: topRight),
            "inputBottomLeft": CIVector(cgPoint: bottomLeft),
            "inputBottomRight": CIVector(cgPoint: bottomRight),
        ])

        let context = CIContext()
        let cgImage = context.createCGImage(ciImage, from: ciImage.extent)
        let output = UIImage(cgImage: cgImage!)
        
        recognizeTextInImage(output)
    }
    
    private func recognizeTextInImage(_ image: UIImage) {
        guard let cgImage = image.cgImage, readyToParseNewData else {
            return
        }
        
        readyToParseNewData = false
        
        textRecognitionWorkQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                try requestHandler.perform([self.textRecognitionRequest])
            } catch {
                print(error)
                self.readyToParseNewData = true
            }
        }
    }

    private func createLayer(in rect: CGRect) {
        maskLayer = CAShapeLayer()
        maskLayer.frame = rect
        maskLayer.cornerRadius = 10
        maskLayer.opacity = 0.75
        maskLayer.borderColor = UIColor.red.cgColor
        maskLayer.borderWidth = 5.0
        
        previewLayer.insertSublayer(maskLayer, at: 1)
    }
    
    private func removeMask() {
        maskLayer.removeFromSuperlayer()
    }
    
}

extension CGPoint {
    
    func scaled(to size: CGSize) -> CGPoint {
        return CGPoint(
            x: self.x * size.width,
            y: self.y * size.height
        )
    }
    
}

enum RegularExpressions {
    
    static let cardNumber: String = "^(\\d{4}-){3}\\d{4}$|^(\\d{4} ){3}\\d{4}$|^\\d{16}$"
    static let cardExpiryDate: String = "^((0[1-9])|(1[0-2]))\\/(\\d{2})$"
    
}

extension String {
    
    var isCardNumber: Bool {
        return isFullyMatchingRegex(RegularExpressions.cardNumber)
    }
    
    var isCardExpiryDate: Bool {
        return isFullyMatchingRegex(RegularExpressions.cardExpiryDate)
    }
    
    var isCardHolder: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let substrings = trimmed.split(separator: " ")
        
        guard substrings.count == 2 else {
            return false
        }
        
        let firstNotMatchingSubstring = substrings.first { substr in
            substr.contains { char in
                !char.isLetter || !char.isUppercase
            }
        }
        
        guard firstNotMatchingSubstring == nil else {
            return false
        }
        
        return true
    }
    
    func isFullyMatchingRegex(_ regex: String) -> Bool {
        let matchingRange = range(of: regex, options: .regularExpression)
        let fullRange = startIndex ..< endIndex
        return matchingRange == fullRange
    }
    
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            debugPrint("unable to get image from sample buffer")
            return
        }
        
        detectRectangle(in: frame)
    }
    
}
