import Foundation
import AVFoundation
import AudioToolbox
import os.log

public class AudioFileManager {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "dev.tuist2.Siri", category: "AudioFileManager")
    private let appGroupID = "group.dev.tuist2.Siri"
    private var audioFileHandle: FileHandle?
    private var currentAudioFileURL: URL?
    private var audioFormat: AVAudioFormat?
    
    // MARK: - Public Methods
    
    /// 开始新的音频录制会话
    public func startNewRecordingSession() -> URL? {
        // 停止之前的录制会话
        stopCurrentRecordingSession()
        
        // 创建音频文件路径
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("❌ 无法获取App Group容器路径")
            return nil
        }
        
        // 创建音频目录
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        if !FileManager.default.fileExists(atPath: audioDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                logger.error("❌ 创建音频目录失败: \(error.localizedDescription)")
                return nil
            }
        }
        
        // 创建新的音频文件
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium).replacingOccurrences(of: ":", with: "-")
        let fileName = "SystemAudio_\(timestamp).m4a"
        let fileURL = audioDirectory.appendingPathComponent(fileName)
        
        currentAudioFileURL = fileURL
        
        logger.info("📝 创建新的音频文件: \(fileName)")
        
        return fileURL
    }
    
    /// 停止当前录制会话
    public func stopCurrentRecordingSession() {
        audioFileHandle?.closeFile()
        audioFileHandle = nil
        
        if let url = currentAudioFileURL {
            logger.info("✅ 音频文件已保存: \(url.lastPathComponent)")
        }
        
        currentAudioFileURL = nil
    }
    
    /// 获取所有录制的音频文件
    public func getAllRecordings() -> [AudioRecording] {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return []
        }
        
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        
        guard FileManager.default.fileExists(atPath: audioDirectory.path) else {
            return []
        }
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
            
            return files.compactMap { url in
                // 包含 m4a 和 wav 文件（包括转换后的文件）
                guard url.pathExtension == "m4a" || url.pathExtension == "wav" else { return nil }
                
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attributes?[.size] as? Int64 ?? 0
                let creationDate = attributes?[.creationDate] as? Date ?? Date()
                
                return AudioRecording(
                    id: UUID().uuidString,
                    fileName: url.lastPathComponent,
                    fileURL: url,
                    creationDate: creationDate,
                    fileSize: fileSize,
                    duration: getAudioDuration(url: url)
                )
            }.sorted { $0.creationDate > $1.creationDate }
        } catch {
            logger.error("❌ 读取音频文件失败: \(error.localizedDescription)")
            return []
        }
    }
    
    /// 删除音频文件
    public func deleteRecording(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            logger.info("🗑️ 已删除音频文件: \(url.lastPathComponent)")
            return true
        } catch {
            logger.error("❌ 删除音频文件失败: \(error.localizedDescription)")
            return false
        }
    }
    
    /// 获取音频时长
    private func getAudioDuration(url: URL) -> TimeInterval {
        let asset = AVAsset(url: url)
        return CMTimeGetSeconds(asset.duration)
    }
    
    /// 清理所有录音文件
    public func clearAllRecordings() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            logger.info("🧹 已清理所有音频文件")
        } catch {
            logger.error("❌ 清理音频文件失败: \(error.localizedDescription)")
        }
    }
    
    /// 将M4A文件转换为WAV格式
    public func convertM4AToWAV(m4aURL: URL) -> URL? {
        logger.info("🔄 开始转换M4A到WAV: \(m4aURL.lastPathComponent)")
        
        // 检查输入文件是否存在
        guard FileManager.default.fileExists(atPath: m4aURL.path) else {
            logger.error("❌ M4A文件不存在: \(m4aURL.path)")
            return nil
        }
        
        // 创建WAV文件路径
        let wavFileName = m4aURL.lastPathComponent.replacingOccurrences(of: ".m4a", with: "_converted.wav")
        let wavURL = m4aURL.deletingLastPathComponent().appendingPathComponent(wavFileName)
        
        logger.info("📥 源文件: \(m4aURL.lastPathComponent)")
        logger.info("📤 目标文件: \(wavFileName)")
        
        // 执行转换
        if convertM4AToWAVUsingExtAudioFile(inputURL: m4aURL, outputURL: wavURL) {
            logger.info("✅ WAV转换成功: \(wavFileName)")
            
            // 验证输出文件
            if FileManager.default.fileExists(atPath: wavURL.path) {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: wavURL.path),
                   let fileSize = attributes[.size] as? Int64 {
                    logger.info("📊 WAV文件大小: \(fileSize) bytes")
                }
                return wavURL
            } else {
                logger.error("❌ WAV文件创建失败")
                return nil
            }
        } else {
            logger.error("❌ WAV转换失败")
            return nil
        }
    }
    
    private func convertM4AToWAVUsingExtAudioFile(inputURL: URL, outputURL: URL) -> Bool {
        var inputFile: ExtAudioFileRef?
        var outputFile: ExtAudioFileRef?
        
        // 打开输入文件
        var status = ExtAudioFileOpenURL(inputURL as CFURL, &inputFile)
        guard status == noErr, let inputFile = inputFile else {
            logger.error("❌ 无法打开输入文件: \(status)")
            return false
        }
        
        // 获取输入文件格式
        var inputFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(inputFile, kExtAudioFileProperty_FileDataFormat, &size, &inputFormat)
        
        logger.info("📊 输入格式: 采样率=\(inputFormat.mSampleRate), 声道=\(inputFormat.mChannelsPerFrame)")
        
        // 设置输出格式 (WAV PCM)
        var outputFormat = AudioStreamBasicDescription()
        outputFormat.mSampleRate = inputFormat.mSampleRate
        outputFormat.mFormatID = kAudioFormatLinearPCM
        outputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian
        outputFormat.mBitsPerChannel = 16
        outputFormat.mChannelsPerFrame = inputFormat.mChannelsPerFrame
        outputFormat.mBytesPerFrame = outputFormat.mChannelsPerFrame * 2
        outputFormat.mFramesPerPacket = 1
        outputFormat.mBytesPerPacket = outputFormat.mBytesPerFrame
        
        logger.info("📤 输出格式: PCM 16-bit, \(outputFormat.mSampleRate)Hz, \(outputFormat.mChannelsPerFrame)声道")
        
        // 创建输出文件
        status = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileWAVEType,
            &outputFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outputFile
        )
        
        guard status == noErr, let outputFile = outputFile else {
            ExtAudioFileDispose(inputFile)
            logger.error("❌ 无法创建输出文件: \(status)")
            return false
        }
        
        // 设置客户端数据格式
        status = ExtAudioFileSetProperty(inputFile, kExtAudioFileProperty_ClientDataFormat, size, &outputFormat)
        guard status == noErr else {
            logger.error("❌ 设置客户端数据格式失败: \(status)")
            ExtAudioFileDispose(inputFile)
            ExtAudioFileDispose(outputFile)
            return false
        }
        
        // 获取文件长度信息
        var fileLengthFrames: Int64 = 0
        var propertySize = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(inputFile, kExtAudioFileProperty_FileLengthFrames, &propertySize, &fileLengthFrames)
        logger.info("📏 输入文件总帧数: \(fileLengthFrames)")
        
        // 读取并写入数据
        let bufferSize: UInt32 = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bufferSize))
        defer { buffer.deallocate() }
        
        var bufferList = AudioBufferList()
        bufferList.mNumberBuffers = 1
        bufferList.mBuffers.mNumberChannels = outputFormat.mChannelsPerFrame
        bufferList.mBuffers.mDataByteSize = bufferSize
        bufferList.mBuffers.mData = UnsafeMutableRawPointer(buffer)
        
        var totalFrames: UInt32 = 0
        
        while true {
            var frameCount: UInt32 = bufferSize / outputFormat.mBytesPerFrame
            
            // 重置buffer大小
            bufferList.mBuffers.mDataByteSize = bufferSize
            
            status = ExtAudioFileRead(inputFile, &frameCount, &bufferList)
            
            if status != noErr {
                logger.error("❌ 读取失败: 状态码=\(status)")
                break
            }
            
            if frameCount == 0 {
                logger.info("✅ 读取完成")
                break
            }
            
            totalFrames += frameCount
            
            status = ExtAudioFileWrite(outputFile, frameCount, &bufferList)
            guard status == noErr else {
                logger.error("❌ 写入失败: 状态码=\(status)")
                break
            }
            
            // 每处理一定数量的帧输出进度
            if totalFrames % 10000 == 0 {
                logger.info("⏳ 已转换 \(totalFrames) 帧...")
            }
        }
        
        logger.info("📝 共转换 \(totalFrames) 帧音频数据")
        
        // 清理
        ExtAudioFileDispose(inputFile)
        ExtAudioFileDispose(outputFile)
        
        return totalFrames > 0
    }
    
    /// 生成高频不可听的M4A音频文件
    public func generateInaudibleAudioFile() -> URL? {
        logger.info("🔊 开始生成高频不可听音频文件...")
        
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("❌ 无法获取App Group容器路径")
            return nil
        }
        
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        if !FileManager.default.fileExists(atPath: audioDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                logger.error("❌ 创建音频目录失败: \(error.localizedDescription)")
                return nil
            }
        }
        
        let fileName = "InaudibleAudio.wav"
        let fileURL = audioDirectory.appendingPathComponent(fileName)
        
        // 如果文件已存在，直接返回
        if FileManager.default.fileExists(atPath: fileURL.path) {
            logger.info("✅ 高频音频文件已存在: \(fileName)")
            return fileURL
        }
        
        // 音频参数
        let sampleRate: Double = 44100.0  // 44.1kHz
        let duration: Double = 0.1        // 0.1秒
        let frequency: Double = 22000.0   // 22kHz - 人耳听不到
        let amplitude: Float = 0.1        // 较小的音量，避免干扰
        
        let frameCount = Int(sampleRate * duration)
        
        // 设置音频格式 - 使用PCM格式便于WAV文件写入
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        // 创建音频缓冲区
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            logger.error("❌ 无法创建音频缓冲区")
            return nil
        }
        
        audioBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // 生成高频正弦波
        guard let leftChannel = audioBuffer.floatChannelData?[0],
              let rightChannel = audioBuffer.floatChannelData?[1] else {
            logger.error("❌ 无法获取音频通道数据")
            return nil
        }
        
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            let sample = Float(sin(2.0 * Double.pi * frequency * time)) * amplitude
            leftChannel[frame] = sample
            rightChannel[frame] = sample
        }
        
        // 使用AVAudioFile直接写入WAV文件
        do {
            let audioFile = try AVAudioFile(forWriting: fileURL, settings: audioFormat.settings)
            try audioFile.write(from: audioBuffer)
            
            logger.info("✅ 高频音频文件生成成功: \(fileName)")
            return fileURL
            
        } catch {
            logger.error("❌ 创建音频文件失败: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Audio Recording Model

public struct AudioRecording: Identifiable {
    public let id: String
    public let fileName: String
    public let fileURL: URL
    public let creationDate: Date
    public let fileSize: Int64
    public let duration: TimeInterval
    
    public var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
    
    public var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "00:00"
    }
}