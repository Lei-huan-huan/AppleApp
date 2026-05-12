//
//  MacGalleryImagesView.swift
//  Photo related
//
//  与 Android MvvmSample 一致：GET {baseURL}/selected，展示 Mac 端勾选图片；可配置 IP/端口、刷新、多选并保存到相册。
//

import Photos
import SwiftUI
import UIKit

// MARK: - API（与 MvvmSample `ApiService` + DTO 对齐）

private struct MacGalleryImageItemDTO: Decodable {
    let name: String?
    let relativePath: String?
    let size: Int64?
    let lastModified: String?
    let url: String?
}

private struct MacGalleryImagesResponseDTO: Decodable {
    let selectedOnly: Bool?
    let count: Int?
    let page: Int?
    let pageSize: Int?
    let totalPages: Int?
    let items: [MacGalleryImageItemDTO]
}

struct MacGalleryImageItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let relativePath: String?
    let size: Int64
    let lastModified: String?

    fileprivate init?(dto: MacGalleryImageItemDTO) {
        guard let raw = dto.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let u = URL(string: raw)
        else { return nil }
        url = u
        id = raw
        let n = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        name = n ?? raw.split(separator: "/").last.map(String.init) ?? "image"
        relativePath = dto.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        size = dto.size ?? 0
        lastModified = dto.lastModified?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - 配置（与 MvvmSample ServerConfigStore 行为一致）

private enum MacGalleryUserDefaults {
    static let ipKey = "MacGalleryServerIP"
    static let portKey = "MacGalleryServerPort"

    static var serverIP: String {
        get { UserDefaults.standard.string(forKey: ipKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: ipKey) }
    }

    static var serverPort: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: portKey)
            return v > 0 ? v : 8080
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    static func baseURL() -> URL? {
        let ip = serverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return nil }
        let port = serverPort
        guard (1 ... 65535).contains(port) else { return nil }
        return URL(string: "http://\(ip):\(port)/")
    }
}

// MARK: - View

struct MacGalleryImagesView: View {
    @State private var items: [MacGalleryImageItem] = []
    @State private var selectedURLs: Set<String> = []
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    @State private var showSettings = false
    @State private var settingsIP = ""
    @State private var settingsPort = ""
    @State private var previewItem: MacGalleryImageItem?

    var body: some View {
        Group {
            if items.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("暂无图片", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("请确认 Mac 端服务已启动，并在右上角设置 IP 与端口后下拉刷新。")
                }
            } else {
                List {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Button {
                                previewItem = item
                            } label: {
                                AsyncImage(url: item.url) { phase in
                                    switch phase {
                                    case .empty:
                                        ProgressView()
                                            .frame(width: 56, height: 56)
                                    case let .success(img):
                                        img
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 56, height: 56)
                                            .clipped()
                                            .cornerRadius(8)
                                    default:
                                        Image(systemName: "photo")
                                            .frame(width: 56, height: 56)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                if let rel = item.relativePath {
                                    Text(rel)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if item.size > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: selectedURLs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedURLs.contains(item.id) ? Color.accentColor : .secondary)
                                .font(.title3)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedURLs.contains(item.id) {
                                selectedURLs.remove(item.id)
                            } else {
                                selectedURLs.insert(item.id)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Mac 端图片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("全选当前列表") {
                        selectedURLs = Set(items.map(\.id))
                    }
                    Button("取消全选") {
                        selectedURLs = []
                    }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing || isLoading)
                    Button {
                        Task { await saveSelectedToPhotos() }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(isSaving || selectedURLs.isEmpty)
                }
            }
        }
        .refreshable {
            await refresh()
        }
        .task {
            await initialLoad()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section("服务器（与 MvvmSample 相同）") {
                        TextField("IP 或主机名", text: $settingsIP)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("端口", text: $settingsPort)
                            .keyboardType(.numberPad)
                    }
                    Section {
                        Text("接口：`GET http://IP:端口/selected`")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Mac 服务设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showSettings = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saveSettingsFromSheet()
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $previewItem) { item in
            MacGalleryImagePreviewView(item: item) {
                previewItem = nil
            }
        }
        .alert("提示", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("完成", isPresented: Binding(
            get: { toastMessage != nil },
            set: { if !$0 { toastMessage = nil } }
        )) {
            Button("好", role: .cancel) { toastMessage = nil }
        } message: {
            Text(toastMessage ?? "")
        }
        .overlay {
            if isLoading && items.isEmpty {
                ProgressView("加载中…")
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if isSaving {
                ProgressView("保存到相册…")
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func openSettings() {
        settingsIP = MacGalleryUserDefaults.serverIP
        settingsPort = String(MacGalleryUserDefaults.serverPort)
        showSettings = true
    }

    private func saveSettingsFromSheet() {
        let ip = settingsIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            errorMessage = "IP 不能为空"
            return
        }
        guard let p = Int(settingsPort.trimmingCharacters(in: .whitespacesAndNewlines)), (1 ... 65535).contains(p) else {
            errorMessage = "端口必须是 1–65535"
            return
        }
        MacGalleryUserDefaults.serverIP = ip
        MacGalleryUserDefaults.serverPort = p
        showSettings = false
        toastMessage = "已保存服务器地址"
        Task { await refresh() }
    }

    private func initialLoad() async {
        await refresh()
    }

    private func refresh() async {
        guard let base = MacGalleryUserDefaults.baseURL() else {
            await MainActor.run {
                items = []
                errorMessage = "请先在右上角设置 Mac 的 IP 与端口"
            }
            return
        }
        let url = base.appendingPathComponent("selected")
        await MainActor.run {
            if items.isEmpty { isLoading = true }
            isRefreshing = true
        }
        defer {
            Task { @MainActor in
                isLoading = false
                isRefreshing = false
            }
        }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "MacGallery", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
            }
            let decoded = try JSONDecoder().decode(MacGalleryImagesResponseDTO.self, from: data)
            let mapped = decoded.items.compactMap(MacGalleryImageItem.init(dto:))
            let unique = Dictionary(grouping: mapped, by: \.id).compactMap { $0.value.first }
            let sorted = unique.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            await MainActor.run {
                items = sorted
                let valid = Set(items.map(\.id))
                selectedURLs = selectedURLs.intersection(valid)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveSelectedToPhotos() async {
        let urls = selectedURLs.compactMap { id in items.first(where: { $0.id == id })?.url }
        guard !urls.isEmpty else {
            await MainActor.run { toastMessage = "请先勾选要保存的图片" }
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            await MainActor.run { errorMessage = "请在系统设置中允许「添加照片」权限" }
            return
        }
        await MainActor.run { isSaving = true }
        defer { Task { @MainActor in isSaving = false } }
        var ok = 0
        for url in urls {
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { continue }
                try await saveImageDataToPhotoLibrary(data, sourceURL: url)
                ok += 1
            } catch {
                continue
            }
        }
        await MainActor.run {
            toastMessage = "已尝试保存 \(ok) / \(urls.count) 张到相册"
        }
    }

    @MainActor
    private func saveImageDataToPhotoLibrary(_ data: Data, sourceURL: URL) async throws {
        guard let image = UIImage(data: data) else {
            throw NSError(domain: "MacGallery", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法解析图片数据: \(sourceURL.lastPathComponent)"])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { success, err in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: err ?? NSError(domain: "MacGallery", code: -1, userInfo: nil))
                }
            })
        }
    }
}

// MARK: - 全屏预览（参照 ImageViewerActivity：大图 + 返回）

private struct MacGalleryImagePreviewView: View {
    let item: MacGalleryImageItem
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: item.url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().tint(.white)
                    case let .success(img):
                        img
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    default:
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", action: onClose)
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
