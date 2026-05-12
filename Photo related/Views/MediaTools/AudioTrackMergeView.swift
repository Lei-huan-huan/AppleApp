//
//  AudioTrackMergeView.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AudioTrackMergeView: View {
    private enum PickerTarget {
        case video
        case audio
    }

    private enum DurationBase: String, CaseIterable, Identifiable {
        case video = "以视频为准"
        case audio = "以音频为准"

        var id: String { rawValue }
    }

    @State private var videoURL: URL?
    @State private var audioURL: URL?
    @State private var outputName = "音轨合并_\(Self.timestampString())"
    @State private var isMerging = false
    @State private var mergeStatus = "请选择画面视频和音轨来源后再合并。"
    @State private var mergedOutputURL: URL?
    @State private var durationBase: DurationBase = .video

    @State private var showSourceDialog = false
    @State private var pickerTarget: PickerTarget = .video
    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var photoPickerTarget: PickerTarget = .video

    var body: some View {
        Form {
            Section("素材选择") {
                sourceRow(
                    title: "画面视频",
                    value: videoURL?.lastPathComponent ?? "未选择"
                ) {
                    pickerTarget = .video
                    showSourceDialog = true
                }

                sourceRow(
                    title: "音轨来源",
                    value: audioURL?.lastPathComponent ?? "未选择"
                ) {
                    pickerTarget = .audio
                    showSourceDialog = true
                }

                Picker("时长策略", selection: $durationBase) {
                    ForEach(DurationBase.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("输出配置") {
                TextField("输出名称（不含 .mov）", text: $outputName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Button {
                    Task { await merge() }
                } label: {
                    HStack {
                        if isMerging {
                            ProgressView()
                                .padding(.trailing, 6)
                        }
                        Text(isMerging ? "合并中…" : "开始音轨合并")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isMerging || videoURL == nil || audioURL == nil)

                if let mergedOutputURL {
                    ShareLink(item: mergedOutputURL) {
                        Label("分享导出文件", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("状态") {
                Text(mergeStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("音轨合并")
        .confirmationDialog("选择来源", isPresented: $showSourceDialog) {
            Button("从文件选择") {
                showFileImporter = true
            }
            Button("从相册选择视频") {
                photoPickerTarget = pickerTarget
                showPhotosPicker = true
            }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: importerTypes(for: pickerTarget),
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result, target: pickerTarget)
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photoPickerItem, matching: .videos)
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            let target = photoPickerTarget
            Task {
                await handlePhotoPick(newItem, target: target)
            }
        }
    }

    @ViewBuilder
    private func sourceRow(title: String, value: String, onTap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip.circle.fill")
                        .foregroundStyle(.tint)
                    Text(value)
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 2)
    }

    private func importerTypes(for target: PickerTarget) -> [UTType] {
        if target == .video {
            return [.movie, .mpeg4Movie, .quickTimeMovie]
        }
        return [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .mpeg4Audio, .wav, .aiff]
    }

    private func handleFileImport(_ result: Result<[URL], Error>, target: PickerTarget) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            guard let copied = copyToTemp(url: url, prefix: target == .video ? "merge_video" : "merge_audio") else {
                mergeStatus = "复制文件失败，请重新选择。"
                return
            }
            switch target {
            case .video:
                videoURL = copied
            case .audio:
                audioURL = copied
            }
        case let .failure(error):
            mergeStatus = "文件选择失败：\(error.localizedDescription)"
        }
    }

    private func handlePhotoPick(_ item: PhotosPickerItem, target: PickerTarget) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                await MainActor.run {
                    mergeStatus = "相册读取失败：未获取到视频数据。"
                    photoPickerItem = nil
                    showPhotosPicker = false
                    photoPickerTarget = .video
                }
                return
            }
            let ext = "mov"
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("merge_photo_\(UUID().uuidString).\(ext)")
            try data.write(to: tempURL, options: .atomic)
            await MainActor.run {
                switch target {
                case .video:
                    videoURL = tempURL
                case .audio:
                    audioURL = tempURL
                }
                showPhotosPicker = false
                photoPickerItem = nil
                photoPickerTarget = .video
            }
        } catch {
            await MainActor.run {
                mergeStatus = "相册读取失败：\(error.localizedDescription)"
                showPhotosPicker = false
                photoPickerItem = nil
                photoPickerTarget = .video
            }
        }
    }

    private func copyToTemp(url: URL, prefix: String) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)_\(url.lastPathComponent)")
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func sanitizedFileStem(_ raw: String) -> String {
        var stem = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocked = CharacterSet(charactersIn: "/\\:?*\"<>|")
        stem = stem.components(separatedBy: blocked).joined()
        while stem.hasPrefix(".") {
            stem = String(stem.dropFirst())
        }
        if stem.isEmpty {
            stem = "音轨合并_\(Self.timestampString())"
        }
        if stem.lowercased().hasSuffix(".mov") {
            stem = String(stem.dropLast(4))
        }
        return stem
    }

    @MainActor
    private func merge() async {
        guard let videoURL, let audioURL else { return }
        isMerging = true
        mergeStatus = "正在合并，请稍候…"
        mergedOutputURL = nil

        do {
            let output = try await mergeVideoAndAudio(
                videoURL: videoURL,
                audioURL: audioURL,
                outputStem: sanitizedFileStem(outputName),
                durationBase: durationBase
            )
            mergedOutputURL = output
            mergeStatus = "合并成功：\(output.lastPathComponent)"
        } catch {
            mergeStatus = "合并失败：\(error.localizedDescription)"
        }

        isMerging = false
    }

    private func mergeVideoAndAudio(
        videoURL: URL,
        audioURL: URL,
        outputStem: String,
        durationBase: DurationBase
    ) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)

        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "AudioMerge", code: 1, userInfo: [NSLocalizedDescriptionKey: "视频来源没有画面轨道。"])
        }
        guard let audioTrack = audioTracks.first else {
            throw NSError(domain: "AudioMerge", code: 2, userInfo: [NSLocalizedDescriptionKey: "音轨来源没有可用音频轨道。"])
        }

        guard videoDuration.isValid, !videoDuration.isIndefinite, CMTimeCompare(videoDuration, .zero) > 0 else {
            throw NSError(domain: "AudioMerge", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法读取视频时长。"])
        }
        guard audioDuration.isValid, !audioDuration.isIndefinite, CMTimeCompare(audioDuration, .zero) > 0 else {
            throw NSError(domain: "AudioMerge", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法读取音轨时长。"])
        }

        let composition = AVMutableComposition()
        guard let composedVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let composedAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "AudioMerge", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法创建合并轨道。"])
        }

        composedVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        switch durationBase {
        case .video:
            try composedVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
            try insertLoopingTimeRange(
                into: composedAudio,
                sourceTrack: audioTrack,
                sourceDuration: audioDuration,
                targetDuration: videoDuration
            )
        case .audio:
            try insertLoopingTimeRange(
                into: composedVideo,
                sourceTrack: videoTrack,
                sourceDuration: videoDuration,
                targetDuration: audioDuration
            )
            try composedAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: .zero)
        }

        let outputURL = try outputURL(stem: outputStem)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "AudioMerge", code: 6, userInfo: [NSLocalizedDescriptionKey: "无法创建导出会话。"])
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        try await export(exporter)
        return outputURL
    }

    private func insertLoopingTimeRange(
        into compositionTrack: AVMutableCompositionTrack,
        sourceTrack: AVAssetTrack,
        sourceDuration: CMTime,
        targetDuration: CMTime
    ) throws {
        var insertAt = CMTime.zero
        while CMTimeCompare(insertAt, targetDuration) < 0 {
            let remaining = CMTimeSubtract(targetDuration, insertAt)
            let chunk = CMTimeMinimum(remaining, sourceDuration)
            let range = CMTimeRange(start: .zero, duration: chunk)
            try compositionTrack.insertTimeRange(range, of: sourceTrack, at: insertAt)
            insertAt = CMTimeAdd(insertAt, chunk)
        }
    }

    private func outputURL(stem: String) throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "AudioMerge", code: 7, userInfo: [NSLocalizedDescriptionKey: "无法定位文稿目录。"])
        }

        var target = docs.appendingPathComponent("\(stem).mov")
        if FileManager.default.fileExists(atPath: target.path) {
            target = docs.appendingPathComponent("\(stem)_\(Self.timestampString()).mov")
        }
        return target
    }

    private func export(_ session: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: session.error ?? NSError(domain: "AudioMerge", code: 8, userInfo: [NSLocalizedDescriptionKey: "导出失败。"]))
                case .cancelled:
                    continuation.resume(throwing: NSError(domain: "AudioMerge", code: 9, userInfo: [NSLocalizedDescriptionKey: "导出已取消。"]))
                default:
                    continuation.resume(throwing: NSError(domain: "AudioMerge", code: 10, userInfo: [NSLocalizedDescriptionKey: "导出状态异常。"]))
                }
            }
        }
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
