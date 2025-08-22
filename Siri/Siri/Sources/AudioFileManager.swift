import Foundation
import AVFoundation
import os.log

public class AudioFileManager {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "dev.tuist.Siri", category: "AudioFileManager")
    private let appGroupID = "group.dev.tuist.Siri"
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
                guard url.pathExtension == "m4a" else { return nil }
                
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