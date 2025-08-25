import ReplayKit
import Foundation
import CoreMedia
import AVFoundation
import AudioToolbox
import os.log

@objc(ScreenBroadcastHandler)
public class ScreenBroadcastHandler: RPBroadcastSampleHandler {
    
    private let logger = Logger(subsystem: "dev.tuist.Siri", category: "ScreenBroadcast")
    private let appGroupID = "group.dev.tuist.Siri"
    
    // 状态管理
    private var isRecording = false
    private var audioFrameCount: Int64 = 0
    
    // 音频录制
    private var audioWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?
    private var currentAudioFileURL: URL?
    private var startTime: CMTime?
    
    // MARK: - Broadcast Lifecycle
    
    public override init() {
        super.init()
        logger.info("🎬 ScreenBroadcastHandler 初始化")
    }
    
    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        logger.info("🚀 屏幕直播开始")
        logger.info("📋 启动参数: \(setupInfo ?? [:])")
        
        // 设置录制状态
        isRecording = true
        audioFrameCount = 0
        startTime = nil
        
        // 开始音频录制
        startAudioRecording()
        
        // 通知主程序直播已开始
        updateStatus(status: "started", message: "屏幕直播已开始")
        
        logger.info("✅ 屏幕直播启动完成")
    }
    
    public override func broadcastFinished() {
        logger.info("🛑 屏幕直播结束")
        
        isRecording = false
        
        // 停止音频录制
        stopAudioRecording()
        
        // 通知主程序直播已结束
        updateStatus(status: "finished", message: "屏幕直播已结束")
        
        logger.info("✅ 屏幕直播结束完成")
    }
    
    public override func finishBroadcastWithError(_ error: Error) {
        logger.error("❌ 屏幕直播发生错误: \(error.localizedDescription)")
        
        isRecording = false
        
        // 停止音频录制
        stopAudioRecording()
        
        // 通知主程序直播发生错误
        updateStatus(status: "error", message: "直播错误: \(error.localizedDescription)")
        
        logger.error("❌ 屏幕直播错误处理完成")
        super.finishBroadcastWithError(error)
    }
    
    // MARK: - Sample Buffer Processing
    
    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isRecording else {
            return
        }
        
        // 检查是否收到停止指令
        checkForStopCommand()
        
        switch sampleBufferType {
        case .audioApp:
            processAppAudio(sampleBuffer)
        case .audioMic:
            processMicAudio(sampleBuffer)
        case .video:
            processVideo(sampleBuffer)
        @unknown default:
            logger.error("❌ 未知的样本缓冲区类型")
        }
    }
    
    // MARK: - Audio Processing
    
    private func processAppAudio(_ sampleBuffer: CMSampleBuffer) {
        audioFrameCount += 1
        
        // 保存音频数据到文件
        saveAudioToFile(sampleBuffer)
        
        // 发送实时音频数据给主程序进行识别
        sendAudioDataForRecognition(sampleBuffer)
        
        // 计算音频电平
        let audioLevel = calculateAudioLevel(sampleBuffer: sampleBuffer)
        
        // 每 30 帧发送一次音频数据到主程序
        if audioFrameCount % 30 == 0 {
            sendAudioDataToMainApp(audioLevel: audioLevel, frameCount: audioFrameCount)
        }
    }
    
    private func processMicAudio(_ sampleBuffer: CMSampleBuffer) {
        // 处理麦克风音频（如果需要）
        logger.debug("🎤 收到麦克风音频数据")
    }
    
    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        // 处理视频数据（如果需要）
        logger.debug("📹 收到视频数据")
    }
    
    // MARK: - Audio Level Calculation
    
    private func calculateAudioLevel(sampleBuffer: CMSampleBuffer) -> Double {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0.0
        }
        
        var dataPointer: UnsafeMutablePointer<Int8>?
        var dataLength: Int = 0
        
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        
        guard status == noErr, let pointer = dataPointer, dataLength > 0 else {
            return 0.0
        }
        
        // 将数据转换为 Float 并计算 RMS
        let samples = pointer.withMemoryRebound(to: Float.self, capacity: dataLength / MemoryLayout<Float>.size) { floatPointer in
            Array(UnsafeBufferPointer(start: floatPointer, count: dataLength / MemoryLayout<Float>.size))
        }
        
        if samples.isEmpty {
            return 0.0
        }
        
        // 计算 RMS (Root Mean Square)
        let sum = samples.reduce(0.0) { $0 + ($1 * $1) }
        let rms = sqrt(Double(sum) / Double(samples.count))
        
        // 转换为分贝并规范化到 0-1 范围
        let decibels = 20 * log10(max(rms, 1e-7))
        let normalizedLevel = max(0.0, min(1.0, (decibels + 60) / 60))
        
        return normalizedLevel
    }
    
    // MARK: - Communication with Main App
    
    private func sendAudioDataToMainApp(audioLevel: Double, frameCount: Int64) {
        let audioData: [String: Any] = [
            "audioLevel": audioLevel,
            "frameCount": frameCount,
            "timestamp": Date().timeIntervalSince1970,
            "isRecording": isRecording
        ]
        
        writeToAppGroup(fileName: "audio_data.json", data: audioData)
        
        logger.info("🎵 发送音频数据: 电平=\(String(format: "%.3f", audioLevel)), 帧数=\(frameCount)")
    }
    
    private func updateStatus(status: String, message: String) {
        let statusData: [String: Any] = [
            "status": status,
            "message": message,
            "timestamp": Date().timeIntervalSince1970,
            "isRecording": isRecording
        ]
        
        writeToAppGroup(fileName: "broadcast_status.json", data: statusData)
        logger.info("📡 状态更新: \(status) - \(message)")
    }
    
    // MARK: - File System Communication
    
    private func writeToAppGroup(fileName: String, data: [String: Any]) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("❌ 无法获取App Group容器路径")
            return
        }
        
        let fileURL = containerURL.appendingPathComponent(fileName)
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
            try jsonData.write(to: fileURL)
        } catch {
            logger.error("❌ 写入App Group文件失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Stop Command Processing
    
    private func checkForStopCommand() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }
        
        let stopCommandURL = containerURL.appendingPathComponent("stop_command.json")
        
        if FileManager.default.fileExists(atPath: stopCommandURL.path) {
            logger.info("📥 收到主程序停止指令")
            
            // 删除指令文件
            try? FileManager.default.removeItem(at: stopCommandURL)
            
            // 停止直播
            finishBroadcastWithError(NSError(domain: "UserRequested", code: 0, userInfo: [NSLocalizedDescriptionKey: "用户通过主程序停止直播"]))
        }
    }
    
    // MARK: - Audio Recording Methods
    
    private func startAudioRecording() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("❌ 无法获取App Group容器路径")
            return
        }
        
        // 创建音频目录
        let audioDirectory = containerURL.appendingPathComponent("AudioRecordings")
        if !FileManager.default.fileExists(atPath: audioDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                logger.error("❌ 创建音频目录失败: \(error.localizedDescription)")
                return
            }
        }
        
        // 创建音频文件
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium).replacingOccurrences(of: ":", with: "-")
        let fileName = "SystemAudio_\(timestamp).m4a"
        currentAudioFileURL = audioDirectory.appendingPathComponent(fileName)
        
        guard let audioFileURL = currentAudioFileURL else { return }
        
        // 设置音频写入器
        do {
            audioWriter = try AVAssetWriter(outputURL: audioFileURL, fileType: .m4a)
            
            // 配置音频设置
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            
            audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioWriterInput?.expectsMediaDataInRealTime = true
            
            if let input = audioWriterInput {
                audioWriter?.add(input)
                audioWriter?.startWriting()
            }
            
            logger.info("🎙️ 开始录制音频: \(fileName)")
            
            // 通知主程序新文件已创建
            notifyAudioFileCreated(fileName: fileName, fileURL: audioFileURL)
            
        } catch {
            logger.error("❌ 创建音频写入器失败: \(error.localizedDescription)")
        }
    }
    
    private func stopAudioRecording() {
        guard let writer = audioWriter else { return }
        
        audioWriterInput?.markAsFinished()
        
        // 保存URL的副本，防止在异步块中被清空
        let audioFileURL = currentAudioFileURL
        
        writer.finishWriting { [weak self] in
            if writer.status == .completed {
                self?.logger.info("✅ 音频文件录制完成")
                if let url = audioFileURL {
                    self?.notifyAudioFileCompleted(fileURL: url)
                    self?.logger.info("📁 M4A文件已保存: \(url.lastPathComponent)")
                }
            } else if let error = writer.error {
                self?.logger.error("❌ 音频文件写入失败: \(error.localizedDescription)")
            }
            
            // 在异步块内清理引用
            self?.audioWriter = nil
            self?.audioWriterInput = nil
            self?.currentAudioFileURL = nil
        }
    }
    
    private func saveAudioToFile(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = audioWriter,
              let input = audioWriterInput,
              writer.status == .writing,
              input.isReadyForMoreMediaData else {
            return
        }
        
        // 设置开始时间
        if startTime == nil {
            startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: startTime!)
        }
        
        // 写入音频数据
        input.append(sampleBuffer)
    }
    
    private func notifyAudioFileCreated(fileName: String, fileURL: URL) {
        let notification: [String: Any] = [
            "event": "audio_file_created",
            "fileName": fileName,
            "filePath": fileURL.path,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        writeToAppGroup(fileName: "audio_notification.json", data: notification)
    }
    
    private func notifyAudioFileCompleted(fileURL: URL) {
        let notification: [String: Any] = [
            "event": "audio_file_completed",
            "fileName": fileURL.lastPathComponent,
            "filePath": fileURL.path,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        writeToAppGroup(fileName: "audio_notification.json", data: notification)
    }
    
    // MARK: - Realtime Audio Recognition
    
    private func sendAudioDataForRecognition(_ sampleBuffer: CMSampleBuffer) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("❌ [Extension] 无法获取App Group容器")
            return
        }
        
        // 获取音频格式描述
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            logger.error("❌ [Extension] 无法获取音频格式描述")
            return
        }
        
        let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let streamDescription = audioStreamBasicDescription else {
            logger.error("❌ [Extension] 无法获取音频流描述")
            return
        }
        
        logger.info("🎵 [Extension] 音频格式 - 采样率: \(streamDescription.pointee.mSampleRate), 声道: \(streamDescription.pointee.mChannelsPerFrame), 格式: \(streamDescription.pointee.mFormatID)")
        
        // 提取音频数据
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            logger.error("❌ [Extension] 无法获取音频缓冲区")
            return
        }
        
        var dataPointer: UnsafeMutablePointer<Int8>?
        var dataLength: Int = 0
        
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        
        guard status == noErr, let pointer = dataPointer, dataLength > 0 else {
            logger.error("❌ [Extension] 音频数据指针获取失败")
            return
        }
        
        // 创建音频格式信息字典
        let audioFormatInfo: [String: Any] = [
            "sampleRate": streamDescription.pointee.mSampleRate,
            "channels": streamDescription.pointee.mChannelsPerFrame,
            "formatID": streamDescription.pointee.mFormatID,
            "formatFlags": streamDescription.pointee.mFormatFlags,  // 关键：添加formatFlags
            "bitsPerChannel": streamDescription.pointee.mBitsPerChannel,
            "bytesPerFrame": streamDescription.pointee.mBytesPerFrame,
            "framesPerPacket": streamDescription.pointee.mFramesPerPacket,
            "bytesPerPacket": streamDescription.pointee.mBytesPerPacket,
            "dataLength": dataLength
        ]
        
        // 将音频数据和格式信息分别写入共享内存
        let audioData = Data(bytes: pointer, count: dataLength)
        let bufferURL = containerURL.appendingPathComponent("realtime_audio_buffer.data")
        let formatURL = containerURL.appendingPathComponent("realtime_audio_format.json")
        
        do {
            // 写入音频数据
            try audioData.write(to: bufferURL)
            
            // 写入格式信息
            let formatData = try JSONSerialization.data(withJSONObject: audioFormatInfo, options: [])
            try formatData.write(to: formatURL)
            
            // 发送Darwin通知告知主程序有新音频数据
            let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
            let notificationName = CFNotificationName("dev.tuist.Siri.audiodata" as CFString)
            CFNotificationCenterPostNotification(darwinCenter, notificationName, nil, nil, true)
            
            logger.debug("✅ [Extension] 音频数据已发送: \(dataLength) bytes, 格式: \(streamDescription.pointee.mFormatID)")
            
        } catch {
            logger.error("❌ [Extension] 写入音频数据失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - M4A to WAV Conversion
    
    private func convertM4AToWAV(m4aURL: URL) {
        logger.info("📌 convertM4AToWAV 函数被调用")
        logger.info("📂 输入文件: \(m4aURL.path)")
        
        // 检查输入文件是否存在
        if !FileManager.default.fileExists(atPath: m4aURL.path) {
            logger.error("❌ 输入文件不存在: \(m4aURL.path)")
            return
        }
        
        // 创建WAV文件路径
        let wavFileName = m4aURL.lastPathComponent.replacingOccurrences(of: ".m4a", with: "_converted.wav")
        let wavURL = m4aURL.deletingLastPathComponent().appendingPathComponent(wavFileName)
        
        logger.info("🔄 开始转换 M4A 到 WAV")
        logger.info("📥 源文件: \(m4aURL.lastPathComponent)")
        logger.info("📤 目标文件: \(wavFileName)")
        logger.info("📍 目标路径: \(wavURL.path)")
        
        if convertM4AToWAVUsingExtAudioFile(inputURL: m4aURL, outputURL: wavURL) {
            logger.info("✅ WAV转换成功: \(wavFileName)")
            
            // 验证输出文件是否存在
            if FileManager.default.fileExists(atPath: wavURL.path) {
                logger.info("✅ WAV文件已创建: \(wavURL.path)")
                
                // 获取文件大小
                if let attributes = try? FileManager.default.attributesOfItem(atPath: wavURL.path),
                   let fileSize = attributes[.size] as? Int64 {
                    logger.info("📊 WAV文件大小: \(fileSize) bytes")
                }
            } else {
                logger.error("❌ WAV文件创建失败，文件不存在")
            }
            
            // 通知主程序WAV文件已创建
            let notification: [String: Any] = [
                "event": "wav_file_converted",
                "fileName": wavFileName,
                "filePath": wavURL.path,
                "originalFile": m4aURL.lastPathComponent,
                "timestamp": Date().timeIntervalSince1970
            ]
            
            writeToAppGroup(fileName: "wav_conversion_notification.json", data: notification)
        } else {
            logger.error("❌ WAV转换失败")
        }
    }
    
    private func convertM4AToWAVUsingExtAudioFile(inputURL: URL, outputURL: URL) -> Bool {
        var inputFile: ExtAudioFileRef?
        var outputFile: ExtAudioFileRef?
        
        // 打开输入文件
        var status = ExtAudioFileOpenURL(inputURL as CFURL, &inputFile)
        guard status == noErr, let inputFile = inputFile else {
            logger.error("❌ 无法打开输入文件: \(inputURL.lastPathComponent)")
            return false
        }
        
        // 获取输入文件格式
        var inputFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(inputFile, kExtAudioFileProperty_FileDataFormat, &size, &inputFormat)
        
        logger.info("📊 输入格式: 采样率=\(inputFormat.mSampleRate), 声道=\(inputFormat.mChannelsPerFrame)")
        
        // 设置输出格式 (WAV PCM) - 添加正确的字节序标志
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
            logger.error("❌ 无法创建输出文件: \(outputURL.lastPathComponent)")
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
        
        return true
    }
}
