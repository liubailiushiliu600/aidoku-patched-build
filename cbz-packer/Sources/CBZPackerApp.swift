import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 数据模型

struct PackedFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let pages: Int
    let bytes: Int64
}

struct PackFailure: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let reason: String
}

// MARK: - 打包核心

enum Packer {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jfif", "png", "webp", "gif",
        "bmp", "tif", "tiff", "avif", "heic", "heif"
    ]

    /// 这些文件名视为封面，不计入页数。
    /// 目的是避免「只有一张 cover.jpg 的文件夹」被误判成一本漫画。
    static let coverStems: Set<String> = ["cover", "!cover", "folder", "backcover", "back-cover"]

    /// 自然排序：1.jpg, 2.jpg, 10.jpg（而不是 1, 10, 2）
    static func naturalSort(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// 取文件夹里（不递归）的图片
    static func images(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let images = items.filter { url in
            guard url.isFileURL, imageExtensions.contains(url.pathExtension.lowercased()) else {
                return false
            }
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            return !coverStems.contains(stem)
        }
        return naturalSort(images)
    }

    /// 取文件夹里的子文件夹
    static func subfolders(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let dirs = items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return naturalSort(dirs)
    }

    /// 递归收集某个文件夹（含所有子目录）里的图片。
    /// 目录按自然序、目录内文件也按自然序，所以结果大致就是阅读顺序。
    static func imagesRecursive(in folder: URL) -> [URL] {
        var all: [URL] = []
        var queue: [URL] = [folder]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            all.append(contentsOf: images(in: current))
            queue.append(contentsOf: subfolders(of: current))
        }
        return all
    }

    /// 按「目标文件夹 → 每个一级子文件夹 = 一本漫画」的结构找出所有漫画。
    ///
    ///     目标文件夹/
    ///         小文件夹A/   →  小文件夹A.cbz
    ///         小文件夹B/   →  小文件夹B.cbz
    ///
    /// 每个一级子文件夹会**整包递归压缩**，所以即使它里面再按话分了子目录，
    /// 也仍然算同一本漫画。Aidoku 是按扩展名跨目录过滤的，能按路径顺序正常读。
    ///
    /// 另外：如果目标文件夹自己就直接放着图片，那它本身也算一本。
    static func books(in root: URL) -> [(folder: URL, images: [URL])] {
        var result: [(URL, [URL])] = []

        let rootImages = images(in: root)
        if !rootImages.isEmpty {
            result.append((root, rootImages))
        }

        for sub in subfolders(of: root) {
            let imgs = imagesRecursive(in: sub)
            if !imgs.isEmpty {
                result.append((sub, imgs))
            }
        }
        return result
    }

    /// 用系统自带的 NSFileCoordinator 把文件夹打成 zip。
    ///
    /// `.forUploading` 会让系统生成一个「临时快照」——对文件夹来说就是一个 zip 包。
    /// 这样完全不需要引入任何第三方压缩库。
    ///
    /// 注意：生成的 zip 内部会带一层同名目录（`作品A/1.jpg`）。
    /// Aidoku 是按扩展名跨目录过滤的，所以能正常读。
    static func makeZip(of folder: URL) throws -> URL {
        var coordError: NSError?
        var produced: URL?
        var copyError: Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { snapshot in
            do {
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cbzpacker-\(UUID().uuidString)")
                    .appendingPathExtension("zip")
                try FileManager.default.copyItem(at: snapshot, to: dest)
                produced = dest
            } catch {
                copyError = error
            }
        }

        if let copyError { throw copyError }
        if let coordError { throw coordError }
        guard let produced else {
            throw NSError(
                domain: "CBZPacker",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "系统没有生成压缩快照"]
            )
        }
        return produced
    }

    /// 清掉文件名里不能用的字符
    static func safeName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}

// MARK: - 状态

@MainActor
final class PackerModel: ObservableObject {
    @Published var isRunning = false
    @Published var status = ""
    @Published var packed: [PackedFile] = []
    @Published var failures: [PackFailure] = []
    @Published var outputDir: URL?

    /// 收件箱：用户把漫画文件夹拖到这里，App 直接扫描，不经过系统文件选择器。
    /// 这条路不涉及安全作用域、不涉及选择器的「选中/进入」语义，最不容易出问题。
    static var inboxURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("输入", isDirectory: true)
    }

    static var outputURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CBZ", isDirectory: true)
    }

    /// 提前把「输入」和「CBZ」两个目录建出来，这样它们在「文件」App 里立刻可见
    func ensureFolders() {
        try? FileManager.default.createDirectory(at: Self.inboxURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.outputURL, withIntermediateDirectories: true)
        outputDir = Self.outputURL
    }

    /// 扫描收件箱并打包
    func runInbox() {
        ensureFolders()
        run(roots: [Self.inboxURL])
    }

    func run(roots: [URL]) {
        guard !isRunning, !roots.isEmpty else { return }
        isRunning = true
        packed = []
        failures = []
        status = "准备中…"
        Task {
            await pack(roots: roots)
            isRunning = false
        }
    }

    private func pack(roots: [URL]) async {
        let fm = FileManager.default
        let outDir = Self.outputURL
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        outputDir = outDir

        for root in roots {
            let scoped = root.startAccessingSecurityScopedResource()
            defer {
                if scoped { root.stopAccessingSecurityScopedResource() }
            }

            let rootName = root.lastPathComponent
            let isInbox = root.standardizedFileURL == Self.inboxURL.standardizedFileURL
            let books = Packer.books(in: root)
            if books.isEmpty {
                let reason = isInbox
                    ? "收件箱里没找到漫画。请把「目标文件夹」整个拖进「输入」目录，里面每个小文件夹算一本。"
                    : "这个文件夹里没找到漫画（里面每个小文件夹应含图片）"
                failures.append(PackFailure(name: rootName, reason: reason))
                continue
            }

            status = "\(rootName)：找到 \(books.count) 本，开始打包…"

            for (index, book) in books.enumerated() {
                let rel = book.folder.pathComponents.dropFirst(root.pathComponents.count)
                let title = rel.isEmpty ? rootName : rel.joined(separator: " - ")
                status = "\(index + 1)/\(books.count)  \(title)"
                await Task.yield()

                do {
                    let zipURL = try Packer.makeZip(of: book.folder)
                    defer { try? fm.removeItem(at: zipURL) }

                    let dest = outDir
                        .appendingPathComponent(Packer.safeName(title))
                        .appendingPathExtension("cbz")
                    try? fm.removeItem(at: dest)
                    try fm.moveItem(at: zipURL, to: dest)

                    let attrs = try? fm.attributesOfItem(atPath: dest.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    packed.append(PackedFile(
                        name: dest.lastPathComponent,
                        url: dest,
                        pages: book.images.count,
                        bytes: size
                    ))
                } catch {
                    failures.append(PackFailure(name: title, reason: error.localizedDescription))
                }
            }
        }

        status = "完成：成功 \(packed.count) 本，失败 \(failures.count) 本"
    }
}

// MARK: - 界面

struct ContentView: View {
    @StateObject private var model = PackerModel()
    @State private var showPicker = false

    var body: some View {
        NavigationView {
            List {
                Section(
                    header: Text("规则"),
                    footer: Text("每个一级小文件夹 = 一本漫画，整包压缩；小文件夹里再分子目录也仍算同一本。")
                        .font(.caption2)
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("目标文件夹/")
                            .font(.system(.caption, design: .monospaced))
                        ruleRow("小文件夹A/", "小文件夹A.cbz")
                        ruleRow("小文件夹B/", "小文件夹B.cbz")
                    }
                    .padding(.vertical, 2)
                }

                Section(
                    header: Text("方式一 · 收件箱（推荐，最稳）"),
                    footer: Text("在「文件」App 里打开：我的 iPad → CBZ 打包器 → 输入\n把「目标文件夹」整个拖进去，再回来点下面的按钮。")
                        .font(.caption2)
                ) {
                    Button {
                        model.runInbox()
                    } label: {
                        Label("扫描收件箱并打包", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(model.isRunning)
                }

                Section(
                    header: Text("方式二 · 直接选择文件夹"),
                    footer: Text("如果系统选择器里文件夹选不中（点「打开」没反应），就用方式一。")
                        .font(.caption2)
                ) {
                    Button {
                        showPicker = true
                    } label: {
                        Label("选择文件夹并打包", systemImage: "folder.badge.plus")
                    }
                    .disabled(model.isRunning)
                }

                if model.isRunning || !model.status.isEmpty {
                    Section("进度") {
                        HStack(spacing: 10) {
                            if model.isRunning {
                                ProgressView()
                            }
                            Text(model.status)
                                .font(.footnote)
                                .lineLimit(3)
                        }
                    }
                }

                if !model.packed.isEmpty {
                    Section("已生成 \(model.packed.count) 个 CBZ") {
                        ForEach(model.packed) { file in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.footnote)
                                    .lineLimit(2)
                                Text("\(file.pages) 页 · \(Self.byteText(file.bytes))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section(
                        header: Text("导出"),
                        footer: Text("一次选中全部 CBZ 分享给 Aidoku，即可批量导入。")
                            .font(.caption2)
                    ) {
                        Button {
                            shareAll()
                        } label: {
                            Label("分享 / 导入到阅读器", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if !model.failures.isEmpty {
                    Section("失败 \(model.failures.count) 个") {
                        ForEach(model.failures) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.footnote)
                                Text(item.reason).font(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                }

                if model.outputDir != nil {
                    Section("输出位置") {
                        Text("文件 App → 我的 iPad → CBZ 打包器 → CBZ")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("CBZ 打包器")
            .onAppear {
                model.ensureFolders()
            }
            // 用单选版本：多选模式下文件夹行点一下往往是「进入」而不是「选中」，
            // 会导致「打开」按钮点了没反应。
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.folder]
            ) { result in
                switch result {
                    case .success(let url):
                        model.run(roots: [url])
                    case .failure(let error):
                        model.status = "选择失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 规则说明里的一行：`小文件夹A/  →  小文件夹A.cbz`
    private func ruleRow(_ folder: String, _ output: String) -> some View {
        HStack(spacing: 6) {
            Text(folder)
                .font(.system(.caption, design: .monospaced))
            Text("→")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(output)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 14)
    }

    private func shareAll() {
        let urls = model.packed.map(\.url)
        guard !urls.isEmpty else { return }

        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard
            let root = scenes.compactMap({ $0.keyWindow }).first?.rootViewController
                ?? scenes.first?.windows.first?.rootViewController
        else { return }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }

        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(
                x: top.view.bounds.midX,
                y: top.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}

// MARK: - 入口

@main
struct CBZPackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
