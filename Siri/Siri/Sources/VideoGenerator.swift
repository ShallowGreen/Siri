import Foundation
import AVFoundation
import UIKit

// MARK: - Video Generator for Picture in Picture
public class VideoGenerator {
    
    // MARK: - Public Methods
    public static func createPlaceholderVideo(width: Int = 2000, height: Int = 400) -> URL? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let videoURL = documentsPath.appendingPathComponent("placeholder_\(width)x\(height).mp4")
        
        print("📹 [VideoGen] 创建占位视频: \(width)x\(height)")
        print("📹 [VideoGen] 视频路径: \(videoURL.path)")
        
        // 删除旧文件
        if FileManager.default.fileExists(atPath: videoURL.path) {
            try? FileManager.default.removeItem(at: videoURL)
        }
        
        guard createVideo(at: videoURL, width: width, height: height) else {
            print("❌ [VideoGen] 视频创建失败")
            return nil
        }
        
        return videoURL
    }
    
    // MARK: - Private Methods
    private static func createVideo(at url: URL, width: Int, height: Int) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            print("❌ [VideoGen] 无法创建视频写入器")
            return false
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2000000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel
            ]
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // 创建10秒循环视频，30fps
        let frameDuration = CMTime(value: 1, timescale: 30)
        let numberOfFrames = 30 * 10
        
        var success = true
        let dispatchGroup = DispatchGroup()
        
        writerInput.requestMediaDataWhenReady(on: DispatchQueue.global()) {
            var frameCount = 0
            
            while frameCount < numberOfFrames && writerInput.isReadyForMoreMediaData {
                let frameTime = CMTime(value: Int64(frameCount), timescale: 30)
                
                guard let pixelBuffer = createPixelBuffer(width: width, height: height) else {
                    success = false
                    break
                }
                
                if !adaptor.append(pixelBuffer, withPresentationTime: frameTime) {
                    print("❌ [VideoGen] 写入帧失败: \(frameCount)")
                    success = false
                    break
                }
                
                frameCount += 1
            }
            
            writerInput.markAsFinished()
            writer.finishWriting {
                if writer.status == .completed {
                    print("✅ [VideoGen] 视频文件创建成功")
                } else {
                    print("❌ [VideoGen] 视频文件创建失败: \(writer.error?.localizedDescription ?? "未知错误")")
                    success = false
                }
                dispatchGroup.leave()
            }
        }
        
        dispatchGroup.enter()
        dispatchGroup.wait()
        
        return success
    }
    
    private static func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32ARGB
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs, &pixelBuffer)
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }
        
        // 创建深色背景，便于测试
        context.setFillColor(UIColor.darkGray.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
