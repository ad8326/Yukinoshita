import AppKit
import SwiftUI
import Darwin

// MARK: - 调试日志（写文件，不依赖系统日志）

func debugLog(_ format: String, _ args: CVarArg...) {
    let line = String(format: format, arguments: args)
    let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SeriesPlayer/saver_debug.log")
    try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let entry = "\(Date()) \(line)\n"
    if let handle = try? FileHandle(forWritingTo: path) {
        handle.seekToEndOfFile()
        handle.write(entry.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? entry.write(to: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - 系统正在播放监听（MediaRemote 私有框架 + 文件旁路）
// 说明：Apple Music 流媒体有 DRM，第三方无法直接播放；歌词也无公开 API。
// 可行方案 = 用户在 Music.app 播放 → 实时读取歌名/歌手/进度 → 用 LRC 同步歌词。
// 新版 macOS 会拒绝 GUI 进程的 MediaRemote 请求（回调不触发），
// 故配有助手进程写 nowplaying.json 的旁路，被拒时自动降级读取。

final class NowPlayingWatcher: ObservableObject {
    static let shared = NowPlayingWatcher()

    @Published var title: String?
    @Published var artist: String?
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Double = 0
    @Published var artwork: NSImage?   // 专辑封面（助手经 iTunes API 抓取）
    private var artworkTS: Double = 0  // 已加载封面的时间戳，避免重复读盘
    private var lastPoll = Date()

    private var getNowPlaying: ((@escaping ([String: Any]) -> Void) -> Void)?
    private var deniedCount = 0            // MediaRemote 被系统拒绝的连续次数
    private var usingFileFallback = false  // 是否已降级到文件旁路
    private var lastLoggedTitle = ""       // 旁路日志去重

    private let fallbackFile: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SeriesPlayer/nowplaying.json")
    }()

    init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
           let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            typealias Fn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
            let fn = unsafeBitCast(sym, to: Fn.self)
            getNowPlaying = { cb in fn(DispatchQueue.global(qos: .utility), cb) }
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// 显示用进度：轮询值 + 本地插值，保证歌词平滑推进
    var displayElapsed: Double {
        elapsed + (rate > 0 ? Date().timeIntervalSince(lastPoll) * rate : 0)
    }

    private func apply(_ title: String, _ artist: String, _ elapsed: Double,
                       _ duration: Double, _ rate: Double) {
        lastPoll = Date()
        self.title = title
        self.artist = artist
        self.elapsed = elapsed
        self.duration = duration
        self.rate = rate
    }

    private func poll() {
        pollArtwork()
        if usingFileFallback {
            readFileFallback()
            return
        }
        guard let fn = getNowPlaying else {
            deniedCount = 999
            usingFileFallback = true
            debugLog("MediaRemote 不可用，降级到文件旁路")
            readFileFallback()
            return
        }
        var responded = false
        fn { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                responded = true
                if let t = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !t.isEmpty {
                    self.deniedCount = 0
                    self.apply(
                        t,
                        (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? "",
                        (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double) ?? 0,
                        (info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double) ?? 0,
                        (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0
                    )
                } else {
                    // 回调触发但内容为空：同样视为被拒，累积切旁路
                    self.deniedCount += 1
                    if self.deniedCount >= 6 {
                        self.usingFileFallback = true
                        debugLog("MediaRemote 回调持续为空，降级到文件旁路")
                        self.readFileFallback()
                    }
                }
            }
        }
        // 关键修复：被拒时回调不会触发，用超时判定切旁路
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !responded, !self.usingFileFallback else { return }
            self.deniedCount += 1
            if self.deniedCount >= 3 {
                self.usingFileFallback = true
                debugLog("MediaRemote 回调超时，降级到文件旁路")
                self.readFileFallback()
            }
        }
    }

    /// 清空现在播放状态（音乐停止/退出后进入待机）
    private func clear() {
        guard title != nil else { return }
        title = nil
        artist = nil
        elapsed = 0
        duration = 0
        rate = 0
        artwork = nil
        lastPoll = Date()
        lastLoggedTitle = ""
        debugLog("播放停止，清空状态进入待机")
    }

    /// 读取助手抓取的专辑封面：artwork.json 记录歌名与时间戳，歌名匹配才采纳
    private func pollArtwork() {
        let dir = fallbackFile.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("artwork.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["ts"] as? Double, ts > artworkTS,
              obj["title"] as? String == title else { return }
        guard let img = NSImage(contentsOf: dir.appendingPathComponent("artwork.jpg")) else { return }
        artworkTS = ts
        artwork = img
    }

    /// 旁路：读取助手进程写入的 nowplaying.json（3 秒内新鲜才算有效）
    private func readFileFallback() {
        guard let data = try? Data(contentsOf: fallbackFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["ts"] as? Double else {
            clear()
            return
        }
        let age = Date().timeIntervalSince1970 - ts
        guard age >= 0, age < 3.0 else {
            clear()
            return
        }
        let t = obj["title"] as? String ?? ""
        if t.isEmpty {
            // 播放已停止（助手写入空标记）：清空状态，让视图进入待机时钟
            clear()
            return
        }
        if t != lastLoggedTitle {
            lastLoggedTitle = t
            debugLog("旁路读取成功：%@ / %@ @ %.1fs", t, obj["artist"] as? String ?? "", obj["elapsed"] as? Double ?? 0)
        }
        apply(
            t,
            obj["artist"] as? String ?? "",
            obj["elapsed"] as? Double ?? 0,
            obj["duration"] as? Double ?? 0,
            obj["rate"] as? Double ?? 0
        )
    }
}

// MARK: - LRC 歌词加载与解析

struct LyricLine { let time: Double; let text: String }

/// 在线歌词抓取：换歌后自动查询公开接口并缓存到 ~/Music/Lyrics（LyricsX 同款路线，个人使用）
enum LyricsFetcher {
    /// 清理查询词：去掉 (Live)/(Remastered)/【…】之类后缀干扰匹配
    private static func clean(_ s: String) -> String {
        var out = s
        for pattern in [#"\（[^）]*\）"#, #"\([^)]*\)"#, #"\【[^】]*\】"#, #"\[[^\]]*\]"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                out = regex.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: out.count), withTemplate: "")
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func fetch(title: String, artist: String?, completion: @escaping ([LyricLine]?) -> Void) {
        let cleanTitle = clean(title)
        let cleanArtist = artist.map { clean($0) }
        let query = ((cleanArtist ?? "") + " " + cleanTitle).trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: "https://music.163.com/api/search/get/web") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = obj["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]] else {
                completion(nil)
                return
            }
            // 优先选歌名与歌手都匹配的结果
            var songID: Double?
            for s in songs {
                let n = (s["name"] as? String) ?? ""
                let arts = ((s["artists"] as? [[String: Any]]) ?? []).compactMap { ($0["name"] as? String) }
                let nameOK = n == cleanTitle || n.contains(cleanTitle)
                let artistOK = cleanArtist == nil || arts.contains { $0.contains(cleanArtist!) }
                if nameOK && artistOK {
                    songID = s["id"] as? Double
                    break
                }
            }
            guard let id = songID,
                  let lurl = URL(string: "https://music.163.com/api/song/lyric?id=\(Int(id))&lv=1&kv=1&tv=-1") else {
                completion(nil)
                return
            }
            URLSession.shared.dataTask(with: lurl) { data2, _, _ in
                guard let data2,
                      let obj2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],
                      let lrc = obj2["lrc"] as? [String: Any],
                      let text = lrc["lyric"] as? String,
                      let lines = LyricsStore.parse(text) else {
                    completion(nil)
                    return
                }
                // 缓存到本地，下次秒载
                if let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
                    let dir = lib.appendingPathComponent("Music/Lyrics")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let name = ((cleanArtist ?? "") + " - " + cleanTitle + ".lrc")
                    try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
                completion(lines)
            }.resume()
        }.resume()
    }
}

enum LyricsStore {
    /// 在 ~/Music/Lyrics 与 App Resources/Lyrics 里按 "歌名.lrc" / "歌手 - 歌名.lrc" 找歌词
    static func load(title: String, artist: String?) -> [LyricLine]? {
        let candidates = (artist.map { [$0 + " - " + title + ".lrc", title + " - " + $0 + ".lrc"] } ?? []) +
            [title + ".lrc"]
        var dirs: [URL] = []
        if let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            dirs.append(lib.appendingPathComponent("Music/Lyrics"))
        }
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("Lyrics"))
        }
        for name in candidates {
            for dir in dirs {
                let url = dir.appendingPathComponent(name)
                if let content = try? String(contentsOf: url, encoding: .utf8),
                   let lines = parse(content), !lines.isEmpty {
                    return lines
                }
            }
        }
        return nil
    }

    static func parse(_ content: String) -> [LyricLine]? {
        var out: [LyricLine] = []
        // 双语 LRC 常见一行多时间戳：[02:10.85][00:58.36]歌词 —— 逐段剥掉所有前导时间戳
        let stampPattern = #"^\s*\[(\d+):(\d+(?:\.\d+)?)\]"#
        let metaPattern = #"^[^:：]{1,6}[:：]"#
        let metaRegex = try? NSRegularExpression(pattern: metaPattern)
        guard let stampRegex = try? NSRegularExpression(pattern: stampPattern) else { return nil }
        for line in content.split(separator: "\n") {
            var rest = String(line)
            var firstTime: Double?
            while true {
                let ns = rest as NSString
                guard let m = stampRegex.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) else { break }
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                if firstTime == nil { firstTime = mm * 60 + ss }
                rest = ns.substring(from: m.range.location + m.range.length)
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard let time = firstTime, !text.isEmpty else { continue }
            // 过滤制作信息行
            if let mr = metaRegex,
               mr.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                continue
            }
            out.append(LyricLine(time: time, text: text))
        }
        return out.isEmpty ? nil : out.sorted { $0.time < $1.time }
    }

    static func currentLineIndex(_ lines: [LyricLine], at t: Double) -> Int {
        let target = t + 0.05
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].time <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower - 1
    }
}

// MARK: - 模拟 Art 1 透明歌词音响（纯音响模式，无视频背景）

/// 无歌可跟时的兜底氛围歌词（原创，规避版权）
let FALLBACK_LYRICS: [String] = [
    "把灯调暗，让音乐接管夜晚",
    "此刻只属于旋律和你",
    "让歌词浮在空气里",
    "去 Music.app 放一首歌吧",
    "夜晚很长，音乐刚好",
]

let PALETTE: [Color] = [
    Color(red: 0.55, green: 0.85, blue: 1.00),   // 冰蓝
    Color(red: 0.75, green: 0.65, blue: 1.00),   // 雾紫
    Color(red: 1.00, green: 0.70, blue: 0.80),   // 暮粉
    Color(red: 1.00, green: 0.85, blue: 0.55),   // 炉火琥珀
    Color(red: 0.60, green: 1.00, blue: 0.85),   // 极光青
]

// MARK: - 显示模式（复刻 Art 1 的歌词动画 / 时钟 / 频谱体系）

enum DisplayMode: Int, CaseIterable, Identifiable {
    case floating   = 0  // 悬浮流动：歌词如水波般浮沉漂移（默认）
    case karaoke    = 1  // 逐字点亮：当前句随演唱进度逐字发光
    case flip       = 2  // 立体翻转：换行时 3D 翻转入场
    case block      = 3  // 经典方块：粗体大字、硬切换、无辉光
    case wave       = 4  // 波动律动：可见行整体随节奏上下起伏
    case meteor     = 5  // 流星划过：当前句从右侧拖尾滑入
    case clock      = 6  // 待机时钟：大数字时钟（极致雅黑风）
    case spectrum   = 7  // 频谱律动：底部律动频谱条 + 当前句

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .floating: return "悬浮流动"
        case .karaoke:  return "逐字点亮"
        case .flip:     return "立体翻转"
        case .block:    return "经典方块"
        case .wave:     return "波动律动"
        case .meteor:   return "流星划过"
        case .clock:    return "待机时钟"
        case .spectrum: return "频谱律动"
        }
    }
}

/// 模式控制：数字键 1-8 直选、←/→ 循环切换，持久化到 UserDefaults
final class ModeController: ObservableObject {
    static let shared = ModeController()
    @Published var mode: DisplayMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "art_display_mode") }
    }
    /// 最近一次切换时间（用于短暂高亮模式名）
    @Published var lastSwitch: Date = .distantPast

    private init() {
        let raw = UserDefaults.standard.integer(forKey: "art_display_mode")
        mode = DisplayMode(rawValue: raw) ?? .floating
    }

    func select(_ m: DisplayMode) {
        guard m != mode else { return }
        mode = m
        lastSwitch = Date()
    }

    func cycle(step: Int) {
        let next = (mode.rawValue + step + DisplayMode.allCases.count) % DisplayMode.allCases.count
        select(DisplayMode(rawValue: next)!)
    }

    /// 换歌时随机换一个模式：排除时钟（无播放时的待机样式）和当前模式，避免连续两首重复
    func randomize() {
        let candidates = DisplayMode.allCases.filter { $0 != .clock && $0 != mode }
        guard let next = candidates.randomElement() else { return }
        mode = next
        lastSwitch = Date()
        debugLog("换歌随机切换模式 → %@", "\(next)")
    }
}

// MARK: - 背景层（艺术/冥想/纯享/照片/专辑/静态/自然动态）
// 背景为低透明度动态氛围，衬在歌词后面（透明屏特性：不抢歌词）

enum BackgroundKind: Int, CaseIterable, Identifiable {
    case art      = 0  // 艺术：流动的抽象光斑，情绪色相缓慢漂移
    case meditation = 1  // 冥想：极缓呼吸的极光光带，宁静治愈
    case pure     = 2  // 纯享：极简黑底 + 上浮微尘 + 呼吸光晕
    case photo    = 3  // 照片：~/Pictures/ArtBackgrounds 轮播 + 缓慢推近
    case album    = 4  // 专辑：实时专辑封面重度模糊衬底（助手抓取）
    case staticBg = 5  // 静态：固定深色渐变，无动画
    case meadow   = 6  // 草原：微风吹动草叶与萤火
    case ocean    = 7  // 海面：层叠潮汐与流动波光
    case snow     = 8  // 冬夜：远山与缓缓飘落的雪
    case rain     = 9  // 雨幕：城市剪影与斜落雨丝

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .art:      return "艺术"
        case .meditation: return "冥想"
        case .pure:     return "纯享"
        case .photo:    return "照片"
        case .album:    return "专辑"
        case .staticBg: return "静态"
        case .meadow:   return "草原微风"
        case .ocean:    return "潮汐海浪"
        case .snow:     return "冬夜飘雪"
        case .rain:     return "雨幕"
        }
    }
}

final class BackgroundController: ObservableObject {
    static let shared = BackgroundController()
    @Published var kind: BackgroundKind {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "art_background_kind") }
    }
    @Published var lastSwitch: Date = .distantPast

    private init() {
        let raw = UserDefaults.standard.integer(forKey: "art_background_kind")
        kind = BackgroundKind(rawValue: raw) ?? .art
    }

    func cycle(step: Int = 1) {
        let next = (kind.rawValue + step + BackgroundKind.allCases.count) % BackgroundKind.allCases.count
        kind = BackgroundKind(rawValue: next)!
        lastSwitch = Date()
    }

    /// 换歌时随机换一个背景：排除当前背景，避免连续两首重复
    func randomize() {
        let candidates = BackgroundKind.allCases.filter { $0 != kind }
        guard let next = candidates.randomElement() else { return }
        kind = next
        lastSwitch = Date()
        debugLog("换歌随机切换背景 → %@", "\(next)")
    }
}

struct ArtSpeakerView: View {
    @ObservedObject var watcher = NowPlayingWatcher.shared
    @ObservedObject var modeCtl = ModeController.shared
    @ObservedObject var bgCtl = BackgroundController.shared
    @State private var fallbackIndex = 0
    @State private var loadedLyrics: [LyricLine]? = nil
    @State private var loadedFor: String = ""
    @State private var isFetching = false
    @State private var photos: [NSImage] = []   // 照片背景轮播源（~/Pictures/ArtBackgrounds）
    private let lineTimer = Timer.publish(every: 6.0, on: .main, in: .common).autoconnect()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                // 面板自适应铺满：任何宽高比（含 21:9 带鱼屏）都占据屏幕绝大部分
                let w = geo.size.width * 0.94
                let h = geo.size.height * 0.92
                // 夜间待机（19:00–7:00）：极低微光，接近墨水屏亮度
                let hour = Calendar.current.component(.hour, from: timeline.date)
                let nightStandby = !hasMusic && (hour >= 19 || hour < 7)
                ZStack {
                    glassPanel(w: w, h: h)
                    if !hasMusic || modeCtl.mode == .clock {
                        clockView(w: w, h: h, t: t)
                    } else if modeCtl.mode == .spectrum {
                        spectrumView(w: w, h: h, t: t)
                    } else if hasMusic {
                        syncedLyrics(w: w, h: h, t: t)
                    } else {
                        fallbackLyrics(w: w, h: h, t: t)
                    }
                    hardware(w: w, h: h, t: t)
                }
                .frame(width: w, height: h)
                .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
                .frame(width: geo.size.width, height: geo.size.height)
                // 背景用 background 附加，铺满整屏且完全不参与布局
                .background(backgroundLayer(w: geo.size.width, h: geo.size.height, t: t))
                // 夜间待机：内容与背景整体压到 15% 微光（墨水屏效果），昼夜切换平滑过渡
                .opacity(nightStandby ? 0.15 : 1)
                .animation(.easeInOut(duration: 3.0), value: nightStandby)
                .clipped()
            }
        }
        .onReceive(lineTimer) { _ in
            if !hasMusic {
                withAnimation(.easeInOut(duration: 1.6)) {
                    fallbackIndex = (fallbackIndex + 1) % FALLBACK_LYRICS.count
                }
            } else if loadedFor != (watcher.title ?? "") {
                // 补偿：App 启动时歌曲已在播（onChange 不会触发初始值），由定时器补调加载
                handleSongChange(watcher.title)
            }
        }
        .onAppear {
            loadPhotos()
            handleSongChange(watcher.title)
        }
        .onChange(of: watcher.title) { _, newTitle in
            handleSongChange(newTitle)
        }
        .background(Color.clear)
        .preferredColorScheme(.dark)
    }

    private var hasMusic: Bool {
        !(watcher.title ?? "").isEmpty
    }

    private var paletteIndex: Int {
        guard hasMusic, let lines = loadedLyrics, !lines.isEmpty else {
            return fallbackIndex % PALETTE.count
        }
        return max(LyricsStore.currentLineIndex(lines, at: watcher.displayElapsed), 0) % PALETTE.count
    }

    // 照片背景源目录：用户自定义照片背景（Art 1 的「自定义照片背景」）
    private func loadPhotos() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/ArtBackgrounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
            ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased())
        } ?? []
        photos = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { NSImage(contentsOf: $0) }
        if !photos.isEmpty {
            debugLog("照片背景加载 %d 张", photos.count)
        }
    }

    // 换歌 → 本地找 LRC → 找不到就在线抓取并缓存
    private func handleSongChange(_ newTitle: String?) {
        guard let title = newTitle, !title.isEmpty else {
            loadedFor = ""
            loadedLyrics = nil
            isFetching = false
            return
        }
        guard loadedFor != title || (loadedLyrics == nil && !isFetching) else { return }
        // 每切一首歌（非启动首次加载）随机换一个动画模式
        let previous = loadedFor
        if !previous.isEmpty && previous != title {
            ModeController.shared.randomize()
            BackgroundController.shared.randomize()
        }
        debugLog("歌曲加载：%@ / %@", title, watcher.artist ?? "-")
        loadedFor = title
        loadedLyrics = LyricsStore.load(title: title, artist: watcher.artist)
        if loadedLyrics != nil {
            debugLog("本地 LRC 命中，共 %d 行", loadedLyrics!.count)
            isFetching = false
            return
        }
        isFetching = true
        let artist = watcher.artist
        LyricsFetcher.fetch(title: title, artist: artist) { lines in
            DispatchQueue.main.async {
                // 只接收仍然匹配当前歌曲的结果，防止快速切歌时串词
                guard loadedFor == title, watcher.title == title else { return }
                debugLog("在线抓取结果：%@（%d 行）", lines == nil ? "失败" : "成功", lines?.count ?? 0)
                loadedLyrics = lines
                isFetching = false
            }
        }
    }

    // MARK: 背景层分发
    private func backgroundLayer(w: CGFloat, h: CGFloat, t: Double) -> some View {
        ZStack {
            Color.black
            Group {
                switch bgCtl.kind {
                case .art:      artBackground(w: w, h: h, t: t)
                case .meditation: meditationBackground(w: w, h: h, t: t)
                case .pure:     pureBackground(w: w, h: h, t: t)
                case .photo:    photoBackground(w: w, h: h, t: t)
                case .album:    albumBackground(w: w, h: h, t: t)
                case .staticBg: staticBackground(w: w, h: h)
                case .meadow:   meadowBackground(w: w, h: h, t: t)
                case .ocean:    oceanBackground(w: w, h: h, t: t)
                case .snow:     snowBackground(w: w, h: h, t: t)
                case .rain:     rainBackground(w: w, h: h, t: t)
                }
            }
            .id(bgCtl.kind)
            .transition(.opacity)
            .animation(.easeInOut(duration: 1.0), value: bgCtl.kind)
            .animation(.easeInOut(duration: 1.4), value: paletteIndex)
        }
    }

    // 艺术背景：2-3 团情绪色光斑缓慢流动变形（Art 1「艺术歌词背景」）
    private func artBackground(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let a = PALETTE[paletteIndex]
        let b = PALETTE[(paletteIndex + 2) % PALETTE.count]
        let c = PALETTE[(paletteIndex + 4) % PALETTE.count]
        return ZStack {
            glowBlob(a, cx: 0.50 + 0.18 * sin(t / 7.0), cy: 0.40 + 0.10 * cos(t / 9.0), r: 0.46, o: 0.22, w: w, h: h)
            glowBlob(b, cx: 0.42 + 0.20 * cos(t / 8.0), cy: 0.58 + 0.13 * sin(t / 6.5), r: 0.40, o: 0.17, w: w, h: h)
            glowBlob(c, cx: 0.58 + 0.14 * sin(t / 10.0), cy: 0.34 + 0.08 * sin(t / 7.5), r: 0.32, o: 0.11, w: w, h: h)
        }
        .clipped()
    }

    private func glowBlob(_ color: Color, cx: Double, cy: Double, r: Double,
                          o: Double, w: CGFloat, h: CGFloat) -> some View {
        RadialGradient(colors: [color.opacity(o), .clear], center: .center,
                       startRadius: 10, endRadius: w * r)
            .frame(width: w * r * 2, height: w * r * 2)
            .position(x: w * CGFloat(cx), y: h * CGFloat(cy))
    }

    // 冥想背景：两道极光色带极缓摆动 + 呼吸明暗（Art 1「冥想歌词背景」）
    private func meditationBackground(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let a = PALETTE[paletteIndex]
        let b = PALETTE[(paletteIndex + 1) % PALETTE.count]
        return ZStack {
            auroraRibbon(a, angle: .degrees(-12 + 4 * sin(t / 11.0)),
                         y: h * (0.38 + 0.04 * sin(t / 13.0)),
                         o: 0.30 + 0.08 * sin(t / 8.0), w: w)
            auroraRibbon(b, angle: .degrees(10 + 3 * cos(t / 9.0)),
                         y: h * (0.62 + 0.04 * cos(t / 12.0)),
                         o: 0.24 + 0.08 * cos(t / 7.0), w: w)
        }
        .clipped()
    }

    private func auroraRibbon(_ color: Color, angle: Angle, y: CGFloat, o: Double, w: CGFloat) -> some View {
        // 画框取正方形，渐变半径恰为半边长 → 四向自然渐隐到 0，再纵向压扁成光带，绝无硬边
        RadialGradient(colors: [color.opacity(o), .clear],
                       center: .center, startRadius: 10, endRadius: w * 0.5)
            .frame(width: w, height: w)
            .scaleEffect(x: 1.0, y: 0.30)
            .blur(radius: 30)
            .rotationEffect(angle)
            .position(x: w * 0.5, y: y)
    }

    // 纯享背景：原黑底呼吸光晕 + 缓慢上浮微尘（Art 1「纯享音乐背景」）
    private func pureBackground(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let accent = PALETTE[paletteIndex]
        return ZStack {
            RadialGradient(
                colors: [accent.opacity(0.10 + 0.04 * sin(t / 5.0)), .clear],
                center: .center, startRadius: 50, endRadius: 700
            )
            // 40 颗微尘：确定性伪随机分布，缓慢上浮 + 闪烁
            ForEach(0..<40, id: \.self) { i in
                let fi = Double(i)
                let x = (0.5 + 0.42 * sin(fi * 12.9898)) * w
                let speed = 8.0 + (fi.truncatingRemainder(dividingBy: 7.0)) * 2.2
                let y = h * (1.05 - ((t / speed + fi * 0.37).truncatingRemainder(dividingBy: 1.1)))
                let twinkle = 0.25 + 0.20 * sin(t * (0.8 + fi * 0.13) + fi)
                Circle()
                    .fill(Color.white.opacity(max(twinkle, 0.03)))
                    .frame(width: 2 + fi.truncatingRemainder(dividingBy: 2.5),
                           height: 2 + fi.truncatingRemainder(dividingBy: 2.5))
                    .position(x: x, y: y)
            }
            .clipped()
        }
    }

    // 草原微风：层叠草坡、随风摆动的草叶与微光萤火
    private func meadowBackground(w: CGFloat, h: CGFloat, t: Double) -> some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.025, green: 0.075, blue: 0.095),
                        Color(red: 0.045, green: 0.14, blue: 0.12),
                        Color(red: 0.025, green: 0.07, blue: 0.065)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            var hill = Path()
            hill.move(to: CGPoint(x: 0, y: size.height * 0.70))
            hill.addCurve(
                to: CGPoint(x: size.width, y: size.height * 0.67),
                control1: CGPoint(x: size.width * 0.30, y: size.height * 0.55),
                control2: CGPoint(x: size.width * 0.68, y: size.height * 0.82)
            )
            hill.addLine(to: CGPoint(x: size.width, y: size.height))
            hill.addLine(to: CGPoint(x: 0, y: size.height))
            hill.closeSubpath()
            context.fill(
                hill,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.07, green: 0.22, blue: 0.15).opacity(0.72),
                        Color(red: 0.025, green: 0.09, blue: 0.075).opacity(0.92)
                    ]),
                    startPoint: CGPoint(x: 0, y: size.height * 0.58),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            for i in 0..<110 {
                let seed = Double(i)
                let x = Double(i) / 109.0 * Double(size.width)
                let baseY = Double(size.height) * (0.73 + 0.13 * (0.5 + 0.5 * sin(seed * 1.71)))
                let bladeHeight = Double(size.height) * (0.035 + 0.09 * (0.5 + 0.5 * sin(seed * 2.37)))
                let wind = sin(t * 0.8 + x / Double(size.width) * 5.0 + seed * 0.18)
                let sway = wind * Double(size.width) * 0.018
                var blade = Path()
                blade.move(to: CGPoint(x: CGFloat(x), y: CGFloat(baseY)))
                blade.addQuadCurve(
                    to: CGPoint(x: CGFloat(x + sway), y: CGFloat(baseY - bladeHeight)),
                    control: CGPoint(x: CGFloat(x + sway * 0.38), y: CGFloat(baseY - bladeHeight * 0.54))
                )
                let green = 0.22 + 0.18 * (0.5 + 0.5 * sin(seed * 0.8))
                context.stroke(
                    blade,
                    with: .color(Color(red: 0.16, green: green, blue: 0.18).opacity(0.48)),
                    lineWidth: 0.8 + CGFloat(seed.truncatingRemainder(dividingBy: 2.0)) * 0.55
                )
            }

            for i in 0..<12 {
                let seed = Double(i)
                let x = (0.12 + 0.76 * (0.5 + 0.5 * sin(seed * 8.3))) * Double(size.width)
                let y = (0.52 + 0.28 * (0.5 + 0.5 * cos(seed * 4.7))) * Double(size.height)
                let pulse = 0.3 + 0.7 * (0.5 + 0.5 * sin(t * 1.8 + seed))
                let radius = 1.2 + pulse * 1.6
                context.fill(
                    Path(ellipseIn: CGRect(x: CGFloat(x - radius), y: CGFloat(y - radius),
                                           width: CGFloat(radius * 2), height: CGFloat(radius * 2))),
                    with: .color(Color(red: 0.78, green: 0.85, blue: 0.48).opacity(0.48 * pulse))
                )
            }
        }
        .frame(width: w, height: h)
    }

    // 潮汐海浪：多层缓慢起伏的海面与漂移波光
    private func oceanBackground(w: CGFloat, h: CGFloat, t: Double) -> some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.015, green: 0.055, blue: 0.12),
                        Color(red: 0.015, green: 0.12, blue: 0.18),
                        Color(red: 0.025, green: 0.07, blue: 0.12)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            for layer in 0..<5 {
                let depth = Double(layer)
                let baseline = Double(size.height) * (0.53 + depth * 0.095)
                let amplitude = Double(size.height) * (0.012 + depth * 0.004)
                let phase = depth * 1.27
                var crest = Path()
                for step in 0...100 {
                    let x = Double(size.width) * Double(step) / 100.0
                    let y = baseline
                        + sin(x / Double(size.width) * 9.0 + t * (0.42 + depth * 0.035) + phase) * amplitude
                        + sin(x / Double(size.width) * 17.0 - t * 0.24 + phase) * amplitude * 0.32
                    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                    if step == 0 {
                        crest.move(to: point)
                    } else {
                        crest.addLine(to: point)
                    }
                }

                var water = crest
                water.addLine(to: CGPoint(x: size.width, y: size.height))
                water.addLine(to: CGPoint(x: 0, y: size.height))
                water.closeSubpath()
                let color = Color(red: 0.035 + depth * 0.008,
                                  green: 0.22 + depth * 0.035,
                                  blue: 0.29 + depth * 0.025)
                context.fill(
                    water,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(0.12), color.opacity(0.52)]),
                        startPoint: CGPoint(x: 0, y: baseline),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
                context.stroke(crest, with: .color(color.opacity(0.22)), lineWidth: 1.2)
            }

            for i in 0..<24 {
                let seed = Double(i)
                let x = (seed * 0.618 + t * (0.008 + seed * 0.00015)).truncatingRemainder(dividingBy: 1.0)
                    * Double(size.width)
                let y = (0.58 + 0.36 * (0.5 + 0.5 * sin(seed * 4.8 + t * 0.34))) * Double(size.height)
                let shimmer = 0.15 + 0.25 * (0.5 + 0.5 * sin(t * 1.4 + seed))
                context.fill(
                    Path(ellipseIn: CGRect(x: CGFloat(x), y: CGFloat(y),
                                           width: CGFloat(2.0 + seed.truncatingRemainder(dividingBy: 2.0)),
                                           height: 1.2)),
                    with: .color(Color(red: 0.47, green: 0.79, blue: 0.76).opacity(shimmer))
                )
            }
        }
        .frame(width: w, height: h)
    }

    // 冬夜飘雪：深色远山衬底与缓慢飘落的雪粒
    private func snowBackground(w: CGFloat, h: CGFloat, t: Double) -> some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.035, green: 0.055, blue: 0.13),
                        Color(red: 0.075, green: 0.10, blue: 0.19),
                        Color(red: 0.035, green: 0.055, blue: 0.12)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            var farMountain = Path()
            farMountain.move(to: CGPoint(x: 0, y: size.height * 0.72))
            farMountain.addLine(to: CGPoint(x: size.width * 0.23, y: size.height * 0.34))
            farMountain.addLine(to: CGPoint(x: size.width * 0.43, y: size.height * 0.69))
            farMountain.addLine(to: CGPoint(x: size.width * 0.67, y: size.height * 0.39))
            farMountain.addLine(to: CGPoint(x: size.width, y: size.height * 0.73))
            farMountain.addLine(to: CGPoint(x: size.width, y: size.height))
            farMountain.addLine(to: CGPoint(x: 0, y: size.height))
            farMountain.closeSubpath()
            context.fill(farMountain, with: .color(Color(red: 0.10, green: 0.13, blue: 0.24).opacity(0.72)))

            var nearMountain = Path()
            nearMountain.move(to: CGPoint(x: 0, y: size.height * 0.83))
            nearMountain.addLine(to: CGPoint(x: size.width * 0.32, y: size.height * 0.58))
            nearMountain.addLine(to: CGPoint(x: size.width * 0.57, y: size.height * 0.82))
            nearMountain.addLine(to: CGPoint(x: size.width * 0.82, y: size.height * 0.56))
            nearMountain.addLine(to: CGPoint(x: size.width, y: size.height * 0.78))
            nearMountain.addLine(to: CGPoint(x: size.width, y: size.height))
            nearMountain.addLine(to: CGPoint(x: 0, y: size.height))
            nearMountain.closeSubpath()
            context.fill(nearMountain, with: .color(Color(red: 0.065, green: 0.095, blue: 0.17).opacity(0.9)))

            for i in 0..<72 {
                let seed = Double(i)
                let speed = 0.018 + seed.truncatingRemainder(dividingBy: 6.0) * 0.004
                let vertical = (t * speed + seed * 0.371).truncatingRemainder(dividingBy: 1.0)
                let horizontal = 0.5 + 0.48 * sin(seed * 12.9898 + t * 0.11 + vertical * 2.0)
                let x = horizontal * Double(size.width)
                let y = vertical * Double(size.height)
                let radius = 0.8 + seed.truncatingRemainder(dividingBy: 2.3)
                let opacity = 0.28 + 0.42 * (0.5 + 0.5 * sin(seed * 2.1 + t))
                context.fill(
                    Path(ellipseIn: CGRect(x: CGFloat(x), y: CGFloat(y),
                                           width: CGFloat(radius * 2), height: CGFloat(radius * 2))),
                    with: .color(Color.white.opacity(opacity))
                )
            }
        }
        .frame(width: w, height: h)
    }

    // 雨幕：低饱和城市剪影与持续落下的细雨
    private func rainBackground(w: CGFloat, h: CGFloat, t: Double) -> some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.035, green: 0.055, blue: 0.09),
                        Color(red: 0.09, green: 0.12, blue: 0.17),
                        Color(red: 0.025, green: 0.045, blue: 0.075)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            for i in 0..<12 {
                let seed = Double(i)
                let buildingWidth = Double(size.width) * (0.045 + 0.025 * (0.5 + 0.5 * sin(seed * 3.2)))
                let x = Double(size.width) * seed / 11.0
                let buildingHeight = Double(size.height) * (0.12 + 0.25 * (0.5 + 0.5 * sin(seed * 2.4 + 0.7)))
                let building = Path(CGRect(x: CGFloat(x), y: CGFloat(Double(size.height) - buildingHeight),
                                           width: CGFloat(buildingWidth), height: CGFloat(buildingHeight)))
                context.fill(building, with: .color(Color(red: 0.045, green: 0.065, blue: 0.095).opacity(0.8)))
            }

            for i in 0..<96 {
                let seed = Double(i)
                let speed = 0.27 + seed.truncatingRemainder(dividingBy: 5.0) * 0.035
                let vertical = (t * speed + seed * 0.319).truncatingRemainder(dividingBy: 1.0)
                let horizontal = (seed * 0.754 + vertical * 0.045).truncatingRemainder(dividingBy: 1.0)
                let x = horizontal * Double(size.width)
                let y = vertical * Double(size.height)
                let length = 7.0 + seed.truncatingRemainder(dividingBy: 10.0)
                var streak = Path()
                streak.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                streak.addLine(to: CGPoint(x: CGFloat(x - length * 0.35), y: CGFloat(y + length)))
                context.stroke(streak, with: .color(Color(red: 0.55, green: 0.68, blue: 0.78).opacity(0.24)),
                               lineWidth: 0.8)
            }
        }
        .frame(width: w, height: h)
    }

    // 照片背景：轮播 + 缓慢推近 + 末段交叉淡化（Art 1「自定义照片背景」）
    private func photoBackground(w: CGFloat, h: CGFloat, t: Double) -> some View {
        Group {
            if photos.isEmpty {
                // 没放照片就退回艺术背景
                artBackground(w: w, h: h, t: t)
            } else {
                let period = 14.0
                let cycle = t / period
                let i = Int(cycle) % photos.count
                let j = (i + 1) % photos.count
                let phase = cycle - floor(cycle)
                let blend = min(max((phase - 0.94) / 0.06, 0), 1)
                ZStack {
                    photoSlide(photos[i], w: w, h: h,
                               scale: 1.04 + 0.07 * phase,
                               opacity: photos.count > 1 ? 1 - blend : 1)
                    if photos.count > 1 && blend > 0 {
                        photoSlide(photos[j], w: w, h: h,
                                   scale: 1.04 + 0.07 * blend,
                                   opacity: blend)
                    }
                }
                .clipped()
                .overlay(Color.black.opacity(0.58))
            }
        }
    }

    private func photoSlide(_ img: NSImage, w: CGFloat, h: CGFloat,
                            scale: CGFloat, opacity: Double) -> some View {
        Image(nsImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: w, height: h)
            .scaleEffect(scale)
            .opacity(opacity)
    }

    // 专辑背景：实时封面重度模糊衬底（Art 1「专辑模式」）；无封面时退回艺术背景
    private func albumBackground(w: CGFloat, h: CGFloat, t: Double) -> some View {
        ZStack {
            if let art = watcher.artwork {
                albumArtLayer(art, w: w, h: h)
            } else {
                artBackground(w: w, h: h, t: t)
            }
        }
        .clipped()
    }

    private func albumArtLayer(_ art: NSImage, w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            Image(nsImage: art)
                .resizable()
                .scaledToFill()
                .frame(width: w, height: h)
                .scaleEffect(1.3)                 // 放大覆盖模糊产生的透明边缘
                .blur(radius: 54)
                .opacity(0.46)
            Color.black.opacity(0.40)             // 压暗：封面只做氛围衬底，不能抢歌词
            vinylRings(w: w)
        }
        .frame(width: w, height: h)
        .clipped()
    }

    // 唱片纹理：一圈圈淡淡的同心圆
    private func vinylRings(w: CGFloat) -> some View {
        ForEach(1..<6, id: \.self) { k in
            Circle()
                .strokeBorder(Color.white.opacity(0.045), lineWidth: 1)
                .frame(width: w * 0.16 * CGFloat(k), height: w * 0.16 * CGFloat(k))
        }
    }

    // 静态背景：固定深色渐变，无任何动画（Art 1「静态背景」）
    private func staticBackground(w: CGFloat, h: CGFloat) -> some View {
        LinearGradient(
            colors: [Color(red: 0.03, green: 0.04, blue: 0.08),
                     Color(red: 0.06, green: 0.07, blue: 0.11)],
            startPoint: .top, endPoint: .bottom
        )
    }

    // 透明玻璃屏：保留内容与背景的通透感，以窄边框和反光勾勒屏体
    private func glassPanel(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.10))
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.055), .clear, .black.opacity(0.10)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.36), .white.opacity(0.10), .white.opacity(0.20)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 1)
                .padding(3)
        }
        .shadow(color: .black.opacity(0.32), radius: 24)
    }

    // 歌词来源：本地/已抓取的 LRC 按当前模式渲染，否则显示歌名卡片或获取中
    private func syncedLyrics(w: CGFloat, h: CGFloat, t: Double) -> some View {
        Group {
            if let lines = loadedLyrics, !lines.isEmpty {
                let idx = max(LyricsStore.currentLineIndex(lines, at: watcher.displayElapsed), 0)
                let accent = PALETTE[paletteIndex]   // 情绪变色：歌词和背景同步换色
                switch modeCtl.mode {
                case .floating: floatingLyrics(lines, idx: idx, w: w, h: h, t: t, accent: accent)
                case .karaoke:  karaokeLyrics(lines, idx: idx, w: w, h: h, t: t, accent: accent)
                case .flip:     flipLyrics(lines, idx: idx, w: w, h: h, t: t, accent: accent)
                case .block:    blockLyrics(lines, idx: idx, w: w, h: h, t: t, accent: accent)
                case .wave:     waveLyrics(lines, idx: idx, w: w, h: h, t: t, accent: accent)
                case .meteor:   meteorLyrics(lines, idx: idx, w: w, h: h, t: t, accent: accent)
                default:        floatingLyrics(lines, idx: idx, w: w, h: h, t: t, accent: accent)
                }
            } else {
                noLyricsCard(w: w, h: h, accent: PALETTE[paletteIndex])
            }
        }
    }

    // 公共脚手架：顶部曲目信息 + 中部动画区 + 底部进度条
    private func lyricScaffold(lines: [LyricLine], idx: Int, w: CGFloat, h: CGFloat,
                               t: Double, accent: Color,
                               @ViewBuilder middle: () -> some View) -> some View {
        VStack(alignment: .center, spacing: 0) {
            Text((watcher.artist ?? "") + " — " + (watcher.title ?? ""))
                .font(.system(size: w * 0.026, weight: .regular))
                .foregroundColor(.white.opacity(0.45))
                .padding(.bottom, h * 0.05)
                .lineLimit(1)
            middle()
                .frame(width: w, height: h * 0.39)
                .clipped()
            Spacer(minLength: 0)
            progressBar(w: w, h: h, accent: accent)
        }
        .padding(.top, h * 0.09)
        .padding(.bottom, h * 0.08)
    }

    // 播放进度条
    private func progressBar(w: CGFloat, h: CGFloat, accent: Color) -> some View {
        GeometryReader { g in
            let p = watcher.duration > 0 ? min(watcher.displayElapsed / watcher.duration, 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(accent.opacity(0.8))
                    .frame(width: g.size.width * p)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, w * 0.10)
    }

    // MARK: 模式 1 悬浮流动（默认）：三行窗口 + 水波漂移
    private func floatingLyrics(_ lines: [LyricLine], idx: Int, w: CGFloat, h: CGFloat,
                                t: Double, accent: Color) -> some View {
        let lineHeight = h * 0.13
        let drift = sin(t / 3.0) * w * 0.012
        return lyricScaffold(lines: lines, idx: idx, w: w, h: h, t: t, accent: accent) {
            ZStack {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    let d = i - idx
                    if abs(d) <= 2 {
                        Text(line.text)
                            .font(.system(size: (d == 0 ? w * 0.042 : w * 0.036),
                                          weight: d == 0 ? .medium : .light))
                            .foregroundColor(.white.opacity(d == 0 ? 0.96 : 0.30))
                            .shadow(color: d == 0 ? accent.opacity(0.85) : .clear, radius: 14)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: w * 0.86, height: lineHeight, alignment: .center)
                            .offset(x: d == 0 ? drift : drift * 0.4,
                                    y: CGFloat(d) * lineHeight)
                            .opacity(d == 0 ? 1.0 : 0.9)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.45), value: idx)
        }
    }

    // MARK: 模式 2 逐字点亮：当前句按演唱进度逐字发光（卡拉OK）
    private func karaokeLyrics(_ lines: [LyricLine], idx: Int, w: CGFloat, h: CGFloat,
                               t: Double, accent: Color) -> some View {
        let lineHeight = h * 0.13
        let chars = Array(lines[idx].text)
        let start = lines[idx].time
        let end = idx + 1 < lines.count ? lines[idx + 1].time : start + 8
        let p = min(max((watcher.displayElapsed - start) / max(end - start, 0.5), 0), 1)
        let n = Double(max(chars.count, 1))
        return lyricScaffold(lines: lines, idx: idx, w: w, h: h, t: t, accent: accent) {
            VStack(spacing: lineHeight * 0.25) {
                if idx > 0 {
                    Text(lines[idx - 1].text)
                        .font(.system(size: w * 0.032, weight: .light))
                        .foregroundColor(.white.opacity(0.28))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: w * 0.86, height: lineHeight * 0.6)
                }
                // 逐字：进度乘以字数得到点亮前沿
                HStack(spacing: 0) {
                    ForEach(Array(chars.enumerated()), id: \.offset) { i, ch in
                        let lit = min(max(p * n - Double(i), 0), 1)
                        Text(String(ch))
                            .font(.system(size: w * 0.042, weight: .medium))
                            .foregroundColor(.white.opacity(0.30 + 0.66 * lit))
                            .shadow(color: accent.opacity(0.85 * lit), radius: 12 * lit)
                    }
                }
                .frame(width: w * 0.86, height: lineHeight, alignment: .center)
                .minimumScaleFactor(0.5)
                if idx + 1 < lines.count {
                    Text(lines[idx + 1].text)
                        .font(.system(size: w * 0.032, weight: .light))
                        .foregroundColor(.white.opacity(0.28))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: w * 0.86, height: lineHeight * 0.6)
                }
            }
        }
    }

    // MARK: 模式 3 立体翻转：换行时 3D 翻转入场（Art 1"立体翻转"字体效果）
    private func flipLyrics(_ lines: [LyricLine], idx: Int, w: CGFloat, h: CGFloat,
                            t: Double, accent: Color) -> some View {
        let lineHeight = h * 0.13
        let age = watcher.displayElapsed - lines[idx].time
        let k = min(max(age / 0.55, 0), 1)
        let angle = (1 - k) * 80
        return lyricScaffold(lines: lines, idx: idx, w: w, h: h, t: t, accent: accent) {
            VStack(spacing: lineHeight * 0.2) {
                if idx > 0 {
                    Text(lines[idx - 1].text)
                        .font(.system(size: w * 0.030, weight: .light))
                        .foregroundColor(.white.opacity(0.24))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: w * 0.86, height: lineHeight * 0.55)
                }
                Text(lines[idx].text)
                    .font(.system(size: w * 0.044, weight: .medium))
                    .foregroundColor(.white.opacity(0.9 + 0.06 * k))
                    .shadow(color: accent.opacity(0.85), radius: 14)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: w * 0.86, height: lineHeight)
                    .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0),
                                      anchor: .bottom, perspective: 0.18)
                    .opacity(0.25 + 0.75 * k)
                if idx + 1 < lines.count {
                    Text(lines[idx + 1].text)
                        .font(.system(size: w * 0.030, weight: .light))
                        .foregroundColor(.white.opacity(0.24))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: w * 0.86, height: lineHeight * 0.55)
                }
            }
        }
    }

    // MARK: 模式 4 经典方块：粗体大字 + 宽字距，硬切换无辉光
    private func blockLyrics(_ lines: [LyricLine], idx: Int, w: CGFloat, h: CGFloat,
                             t: Double, accent: Color) -> some View {
        let lineHeight = h * 0.13
        return lyricScaffold(lines: lines, idx: idx, w: w, h: h, t: t, accent: accent) {
            VStack(spacing: lineHeight * 0.2) {
                Text(lines[idx].text)
                    .font(.system(size: w * 0.040, weight: .bold))
                    .tracking(w * 0.006)
                    .foregroundColor(.white.opacity(0.92))
                    .shadow(color: accent.opacity(0.35), radius: 6)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: w * 0.86, height: lineHeight)
                    .id(idx)   // 硬切换：不加动画修饰
                if idx + 1 < lines.count {
                    Text(lines[idx + 1].text)
                        .font(.system(size: w * 0.026, weight: .regular))
                        .tracking(w * 0.004)
                        .foregroundColor(.white.opacity(0.30))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: w * 0.80, height: lineHeight * 0.5)
                }
            }
        }
    }

    // MARK: 模式 5 波动律动：可见行随节奏正弦起伏、辉光呼吸
    private func waveLyrics(_ lines: [LyricLine], idx: Int, w: CGFloat, h: CGFloat,
                            t: Double, accent: Color) -> some View {
        let lineHeight = h * 0.13
        return lyricScaffold(lines: lines, idx: idx, w: w, h: h, t: t, accent: accent) {
            ZStack {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    let d = i - idx
                    if abs(d) <= 1 {
                        let bob = sin(t * 2.5 + Double(i) * 0.9) * h * 0.016
                        Text(line.text)
                            .font(.system(size: (d == 0 ? w * 0.042 : w * 0.034),
                                          weight: d == 0 ? .medium : .light))
                            .foregroundColor(.white.opacity(d == 0 ? 0.96 : 0.28))
                            .shadow(color: d == 0 ? accent.opacity(0.6 + 0.3 * sin(t * 6.0)) : .clear,
                                    radius: 10 + 5 * (d == 0 ? sin(t * 6.0) : 0))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(width: w * 0.86, height: lineHeight, alignment: .center)
                            .offset(y: CGFloat(d) * lineHeight + bob)
                    }
                }
            }
        }
    }

    // MARK: 模式 6 流星划过：当前句从右侧拖尾滑入，停留后向左淡出
    private func meteorLyrics(_ lines: [LyricLine], idx: Int, w: CGFloat, h: CGFloat,
                              t: Double, accent: Color) -> some View {
        let lineHeight = h * 0.13
        let start = lines[idx].time
        let end = idx + 1 < lines.count ? lines[idx + 1].time : start + 8
        let p = (watcher.displayElapsed - start) / max(end - start, 1)
        // 入场 0.35 行程：右→中；离场最后 0.15 行程：中→左
        var xOff: CGFloat = 0
        var speedGlow: Double = 0
        if p < 0.35 {
            let k = 1 - p / 0.35   // 1→0
            xOff = CGFloat(k * k) * w * 0.5
            speedGlow = k * 22
        } else if p > 0.85 {
            let k = (p - 0.85) / 0.15
            xOff = -CGFloat(k * k) * w * 0.5
            speedGlow = k * 22
        }
        return lyricScaffold(lines: lines, idx: idx, w: w, h: h, t: t, accent: accent) {
            VStack(spacing: lineHeight * 0.2) {
                if idx > 0 {
                    Text(lines[idx - 1].text)
                        .font(.system(size: w * 0.028, weight: .light))
                        .foregroundColor(.white.opacity(0.20))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: w * 0.80, height: lineHeight * 0.5)
                }
                Text(lines[idx].text)
                    .font(.system(size: w * 0.043, weight: .medium))
                    .foregroundColor(.white.opacity(0.96))
                    .shadow(color: accent.opacity(0.9), radius: 12 + speedGlow)
                    .shadow(color: accent.opacity(0.5), radius: 24 + speedGlow * 1.5)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: w * 0.86, height: lineHeight)
                    .offset(x: xOff)
                if idx + 1 < lines.count {
                    Text(lines[idx + 1].text)
                        .font(.system(size: w * 0.028, weight: .light))
                        .foregroundColor(.white.opacity(0.20))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: w * 0.80, height: lineHeight * 0.5)
                }
            }
        }
    }

    // MARK: 模式 7 待机时钟（极致雅黑风：细体大数字 + 日期）
    private func clockView(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let accent = PALETTE[paletteIndex]
        let now = Date()
        let cal = Calendar.current
        let timeStr = cal.component(.hour, from: now) >= 10
            ? String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
            : String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 EEEE"
        let dateStr = fmt.string(from: now)
        return VStack(spacing: h * 0.03) {
            Text(timeStr)
                .font(.system(size: w * 0.16, weight: .thin))
                .foregroundColor(.white.opacity(0.95))
                .shadow(color: accent.opacity(0.5), radius: 24)
            Text(dateStr)
                .font(.system(size: w * 0.030, weight: .light))
                .foregroundColor(.white.opacity(0.45))
                .tracking(w * 0.008)
        }
        .opacity(0.92 + 0.08 * sin(t / 4.0))
    }

    // MARK: 模式 8 频谱律动：伪频谱条 + 当前句小字（无 LRC 也有效）
    private func spectrumView(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let accent = PALETTE[paletteIndex]
        let bars = 36
        let beat = watcher.rate > 0 ? watcher.displayElapsed : t
        return VStack(spacing: h * 0.06) {
            if let lines = loadedLyrics, !lines.isEmpty {
                let idx = max(LyricsStore.currentLineIndex(lines, at: watcher.displayElapsed), 0)
                Text(lines[idx].text)
                    .font(.system(size: w * 0.036, weight: .light))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(color: accent.opacity(0.7), radius: 12)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: w * 0.86, height: h * 0.10)
            } else if hasMusic {
                Text((watcher.title ?? "") + " · " + (watcher.artist ?? ""))
                    .font(.system(size: w * 0.030, weight: .light))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: w * 0.86, height: h * 0.10)
            } else {
                Text(FALLBACK_LYRICS[fallbackIndex])
                    .font(.system(size: w * 0.032, weight: .light))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: w * 0.86, height: h * 0.10)
            }
            HStack(alignment: .bottom, spacing: w * 0.004) {
                ForEach(0..<bars, id: \.self) { i in
                    let x = Double(i) / Double(bars)
                    let v1 = 0.5 + 0.5 * sin(beat * (2.0 + x * 3.0) + Double(i) * 1.7)
                    let v2 = 0.5 + 0.5 * sin(beat * 4.3 + Double(i % 7) * 2.1)
                    let vol = 0.12 + 0.6 * (v1 * 0.6 + v2 * 0.4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.25)],
                                             startPoint: .bottom, endPoint: .top))
                        .frame(width: w * 0.014, height: h * 0.24 * vol)
                }
            }
            .frame(height: h * 0.24, alignment: .bottom)
        }
    }

    // 找不到 LRC：歌名大字发光 + 提示
    private func noLyricsCard(w: CGFloat, h: CGFloat, accent: Color) -> some View {
        VStack(spacing: h * 0.05) {
            Text(watcher.title ?? "")
                .font(.system(size: w * 0.055, weight: .medium))
                .foregroundColor(.white.opacity(0.96))
                .shadow(color: accent.opacity(0.85), radius: 16)
                .shadow(color: accent.opacity(0.45), radius: 38)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(watcher.artist ?? "")
                .font(.system(size: w * 0.032, weight: .light))
                .foregroundColor(.white.opacity(0.5))
            Text(isFetching ? "正在获取歌词…" : "未找到歌词 · LRC 自动下载失败")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.28))
        }
    }

    // 兜底氛围歌词（无歌播放时）
    private func fallbackLyrics(w: CGFloat, h: CGFloat, t: TimeInterval) -> some View {
        let accent = PALETTE[fallbackIndex % PALETTE.count]
        let drift = CGFloat(sin(t / 4.0) * 7.0)
        return Text(FALLBACK_LYRICS[fallbackIndex])
            .font(.system(size: w * 0.055, weight: .light))
            .foregroundColor(.white.opacity(0.85))
            .shadow(color: accent.opacity(0.8), radius: 16)
            .shadow(color: accent.opacity(0.4), radius: 36)
            .offset(x: drift)
            .id(fallbackIndex)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                )
            )
            .animation(.easeInOut(duration: 1.6), value: fallbackIndex)
    }

    // 设备状态栏：品牌标识与当前播放状态固定在玻璃屏边缘
    private func hardware(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let sinceSwitch = Date().timeIntervalSince(modeCtl.lastSwitch)
        let modeOpacity = sinceSwitch < 2.5 ? 0.85 : 0.28   // 切换后短暂高亮
        let sinceBgSwitch = Date().timeIntervalSince(bgCtl.lastSwitch)
        let bgOpacity = sinceBgSwitch < 2.5 ? 0.85 : 0.24
        return VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("ART MASTER")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(5)
                    .foregroundColor(.white.opacity(0.68))
                Spacer()
                HStack(spacing: 7) {
                    Circle()
                        .fill(hasMusic ? Color(red: 0.45, green: 0.88, blue: 0.76) : .white.opacity(0.35))
                        .frame(width: 5, height: 5)
                    Text(hasMusic ? "NOW PLAYING" : "STANDBY")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.6)
                        .foregroundColor(.white.opacity(0.42))
                }
            }
            .padding(.top, h * 0.035)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
                .padding(.top, h * 0.018)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Text("ART·1")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(3)
                    .foregroundColor(.white.opacity(0.28))
                Text("\(modeCtl.mode.rawValue + 1) · \(modeCtl.mode.name)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(modeOpacity))
                Text("·")
                    .foregroundColor(.white.opacity(0.22))
                Text("\(bgCtl.kind.name)背景")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(bgOpacity))
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(0..<5, id: \.self) { _ in
                        Capsule()
                            .fill(Color.white.opacity(0.20))
                            .frame(width: 12, height: 2)
                    }
                }
            }
            .padding(.bottom, h * 0.035)
        }
        .padding(.horizontal, w * 0.045)
        .allowsHitTesting(false)
    }
}

// MARK: - 应用代理：全屏窗口 + 防休眠断言 + 交互退出

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var systemToken: NSObjectProtocol?    // 永久持有：防止系统休眠（保证 7 点定时器能触发）
    private var displayToken: NSObjectProtocol?   // 可释放：防止显示器休眠
    private var displaySleeping = false
    private var cursorTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        systemToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "屏保需要保持系统唤醒以定时点亮屏幕"
        )
        displayToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Yukinoshita 常亮屏保"
        )
        startIdleMonitor()
        NSApp.setActivationPolicy(.accessory)

        // 优先使用面积最大的显示器（带鱼屏等外接大屏）
        let screen = NSScreen.screens.max {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        } ?? NSScreen.main
        guard let screen else { NSApp.terminate(nil); return }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let artView = NSHostingView(rootView: ArtSpeakerView())
        artView.frame = screen.frame
        artView.autoresizingMask = [.width, .height]
        window.contentView = artView

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        NSCursor.hide()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            NSCursor.hide()
        }

        // 夜间待机管理：10 分钟无输入 → 屏幕休眠；7 点（或恢复播放）→ 唤醒
        // 见 startIdleMonitor()

        // 启动 12 秒后自渲染一次窗口快照（调试验证用）
        Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak window] _ in
            guard let view = window?.contentView else { return }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("SeriesPlayer")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: dir.appendingPathComponent("ui_snapshot.png"))
            }
        }

        // 键盘交互：1-8 直选动画模式，←/→ 循环切换，Esc/Q 退出；其他按键退出
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                if chars == "\u{1B}" || chars.lowercased() == "q" {
                    NSApp.terminate(nil)
                    return nil
                }
                if let digit = chars.first?.wholeNumberValue,
                   digit >= 1, digit <= DisplayMode.allCases.count {
                    ModeController.shared.select(DisplayMode.allCases[digit - 1])
                    return nil
                }
                switch event.keyCode {
                case 123: ModeController.shared.cycle(step: -1); return nil   // ←
                case 124: ModeController.shared.cycle(step: 1); return nil    // →
                default: break
                }
                if chars.lowercased() == "m" {
                    ModeController.shared.cycle(step: 1)
                    return nil
                }
                if chars.lowercased() == "b" {
                    BackgroundController.shared.cycle()
                    return nil
                }
            }
            NSApp.terminate(nil)
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { _ in
            NSApp.terminate(nil)
            return nil
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { _ in
            NSApp.terminate(nil)
        }
    }

    // MARK: 夜间待机休眠/定时唤醒
    /// 系统级无输入时长（鼠标/键盘/滚轮，取多事件类型最小值）
    private func systemIdleSeconds() -> Double {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .otherMouseDown, .keyDown, .scrollWheel,
                                    .leftMouseDragged, .otherMouseDragged]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }

    private func startIdleMonitor() {
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkIdleSleep()
        }
    }

    private func checkIdleSleep() {
        let hour = Calendar.current.component(.hour, from: Date())
        let playing = !(NowPlayingWatcher.shared.title ?? "").isEmpty
        let dayTime = hour >= 7 && hour < 19

        if displaySleeping {
            if dayTime || playing {
                wakeDisplay(reason: dayTime ? "到达 7 点唤醒时间" : "恢复播放")
            } else if systemIdleSeconds() < 600 {
                // 用户输入已把屏幕点亮：回到正常夜间待机，重新计时
                displaySleeping = false
                reassertDisplay()
                debugLog("用户活动唤醒屏幕，重新进入夜间待机计时")
            }
            return
        }
        // 夜间待机 + 10 分钟无输入 → 主动让显示器休眠
        if !playing && !dayTime && systemIdleSeconds() >= 600 {
            sleepDisplay()
        }
    }

    private func sleepDisplay() {
        debugLog("夜间待机 10 分钟无输入，显示器休眠（7 点自动唤醒）")
        if let token = displayToken {
            ProcessInfo.processInfo.endActivity(token)
            displayToken = nil
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try? p.run()
            DispatchQueue.main.async { self?.displaySleeping = true }
        }
    }

    private func wakeDisplay(reason: String) {
        displaySleeping = false
        debugLog("%@，唤醒屏幕", reason)
        reassertDisplay()
        // caffeinate -u 发出用户活动声明，把已睡的显示器拉亮（约 10 秒窗口）
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-u", "-t", "10"]
            try? p.run()
            p.waitUntilExit()
        }
    }

    private func reassertDisplay() {
        if displayToken == nil {
            displayToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Yukinoshita 常亮屏保"
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let token = systemToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        if let token = displayToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        cursorTimer?.invalidate()
        NSCursor.unhide()
        window?.orderOut(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
