# HokkaidoSnowSaver — ART·1 透明歌词音响模拟屏保

在 macOS 上全屏模拟 ART' MASTER Art 1 透明玻璃歌词音响：读取 Apple Music 正在播放的歌曲，
自动联网抓取 LRC 歌词，按多种动画模式逐句同步显示；闲置时可用待机时钟或频谱律动。
运行期间持有防显示器休眠断言。

纯 AppKit + SwiftUI 单文件编译，无需 Xcode 工程。

## 直接使用

双击 `build/HokkaidoSnowSaver.app`：立即全屏进入，铺满任意宽高比（含 21:9 带鱼屏）。

### 键盘交互（复刻实体旋钮的用法）

| 按键 | 作用 |
| --- | --- |
| `1` – `8` | 直接切换到对应动画模式 |
| `←` / `→` 或 `M` | 上/下一个模式循环切换 |
| `B` | 循环切换背景（艺术/冥想/纯享/照片/专辑/静态） |
| `Esc` 或 `Q` | 退出屏保 |
| 其他任意键 / 鼠标点击 / 滚动 | 退出屏保 |

当前模式名与背景名显示在面板底部（切换后会短暂高亮），选择会被记住（UserDefaults）。
每次切歌会自动随机换一个歌词动画模式（排除待机时钟）。

## 背景体系（对齐 Art 1 的 APP「背景」菜单）

| # | 背景 | 效果 |
| --- | --- | --- |
| 1 | 艺术 | 2-3 团情绪色光斑缓慢流动变形（默认） |
| 2 | 冥想 | 两道极缓摆动的极光光带，呼吸式明暗，宁静治愈 |
| 3 | 纯享 | 极简黑底 + 呼吸光晕 + 40 颗缓慢上浮的微尘 |
| 4 | 照片 | `~/Pictures/ArtBackgrounds` 内照片轮播（14 秒一张，缓慢推近 + 交叉淡化） |
| 5 | 专辑 | 实时专辑封面（助手经 iTunes API 抓取）重度模糊压暗后做氛围衬底 + 唱片同心圆纹理 |
| 6 | 静态 | 固定深色渐变，无任何动画 |

背景一律低透明度衬在歌词后才（透明屏特性：不抢歌词）。照片背景把图片放进
`~/Pictures/ArtBackgrounds/`（jpg/png/heic）即可自动轮播；目录为空时自动退回艺术背景。

## 动画模式（对齐 Art 1 的官方效果体系）

| # | 模式 | 效果 |
| --- | --- | --- |
| 1 | 悬浮流动 | 歌词像水波一样浮沉漂移，当前句居中发光（默认） |
| 2 | 逐字点亮 | 当前句随演唱进度逐字变亮（卡拉 OK 效果） |
| 3 | 立体翻转 | 每句换行时 3D 翻转入场（对应 Art 1「立体翻转」字体效果） |
| 4 | 经典方块 | 粗体大字 + 宽字距、硬切换（对应「经典方块」字体效果） |
| 5 | 波动律动 | 上下句随节奏正弦起伏、辉光呼吸 |
| 6 | 流星划过 | 当前句从右侧拖尾滑入、末尾向左离场（流星歌词） |
| 7 | 待机时钟 | 细体大数字时钟 + 日期秒数（对应「极致雅黑」待机样式） |
| 8 | 频谱律动 | 36 条律动频谱柱 + 当前歌词（纯享音乐背景） |

所有歌词模式都带「情绪变色」：每句歌词轮换一个色相（冰蓝 → 雾紫 → 暮粉 → 琥珀 → 极光青）。

## 歌词来源

1. 本地 `~/Music/Lyrics/`（或 App 内 Resources/Lyrics）下的 `歌名.lrc` / `歌手 - 歌名.lrc`
2. 没有本地文件时自动联网抓取（网易云公开歌词接口），成功后缓存到本地，下次秒加载
3. 双语多时间戳 LRC（`[02:10.85][00:58.36]歌词`）、制作信息行（作词/作曲/编曲…）均已处理

## 运行依赖

- 需要 `np_helper` 助手进程把「系统正在播放」写到 `~/Library/Application Support/SeriesPlayer/nowplaying.json`
  （新版 macOS 拒绝 GUI 进程访问 MediaRemote，助手用命令行上下文轮询，带 PID 单实例锁）
- 启动助手：`cd SeriesPlayer && swift np_helper.swift &`

## 开机自启

系统设置 → 通用 → 登录项 → 添加本 App。

## 重新构建

```bash
./build.sh
```

启动 12 秒后会在 `~/Library/Application Support/SeriesPlayer/ui_snapshot.png` 写一张窗口自渲染快照，
方便在没有录屏权限的环境下排查显示问题。

## 关键实现

- `NowPlayingWatcher`：MediaRemote 私有框架轮询 + 1.5s 超时降级到 JSON 文件旁路
- `LyricsStore.parse`：多时间戳 LRC 解析、元信息过滤、按时间二分定位当前行
- `ModeController`：8 种显示模式，`@Published` 驱动 SwiftUI 重绘，持久化到 UserDefaults
- `BackgroundController`：6 种背景，`B` 键循环；背景用 `.background()` 附加，不参与面板布局
- 专辑封面：MediaRemote 无 artwork 接口，改由助手走 iTunes Search API 抓 1200×1200 图落盘
  （`artwork.jpg` + `artwork.json` 记录歌名与时间戳，歌名匹配才采纳，防串封面）
- `ProcessInfo.beginActivity(.idleDisplaySleepDisabled)`：防休眠断言，token 持有到退出
- 窗口 `level = .screenSaver` + `canJoinAllSpaces`，自动选择面积最大的显示器
