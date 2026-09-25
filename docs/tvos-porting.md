# momo-music tvOS 移植方案

> **摘要**：本文档是 momo-music（当前为 Electron 37 + Vue3 + TypeScript + Pinia + Vue Router + vue-i18n，版本 3.3.5，作者 klzbw，仓库 https://github.com/klzbw/momo-music ）从 Electron 桌面端移植到 Apple TV（目标平台 **tvOS 27**，需 Xcode 26+）的完整技术方案。
>
> 核心硬约束：**Electron 不支持 tvOS**，必须换壳；tvOS 无 Node.js 运行时、无任意文件系统访问、无本地 SQLite，且 tvOS WebKit 对 Web Audio API 支持有限。本方案选定 **Capacitor 6 + 官方 `@capacitor/tvos`** 作为移植壳，最大化复用现有 Vue3 renderer 代码，仅对 Electron 专属能力（本地音乐扫描、Web Audio 音效、原生数据库、Worker 线程、系统级集成等）做裁剪或降级。文档分为：技术选型结论、Capacitor 集成方案、tvOS UI 适配清单、功能裁剪清单、已知限制与后续手动步骤五部分。

---

## 1. 技术选型结论

### 1.1 四条候选路径对比

| 对比维度 | Capacitor 6（`@capacitor/tvos`） | Flutter 重写 | React Native 重写（react-native-tvos） | SwiftUI 原生壳 + WKWebView 包装 Vue3 |
|---|---|---|---|---|
| **现有 Vue3 代码复用率** | **≈ 90%+**：整个 `src/renderer/`（Vue 组件、Pinia store、Vue Router、vue-i18n）直接复用，只需替换 IPC 层与少数 Electron 专属依赖 | 0%：UI 层全部用 Dart/Flutter Widget 重写，业务逻辑可移植思想但代码不复用 | 0%：Vue SFC 无法直接跑在 RN 上，组件树需用 RN 组件重写 | ≈ 85%：Vue3 代码原样塞进 WKWebView，但需自己写原生桥 |
| **tvOS 原生能力接入** | **官方维护 tvOS target**，Focus Engine / Siri Remote / 后台音频通过 Capacitor plugin 桥接，社区插件生态相对完整 | 中等：Flutter 官方 embedder 支持 tvOS，Platform Channel 可桥接，但部分插件无 tvOS 实现 | 中等：`react-native-tvos` 社区 fork 对 Focus 有适配，但生态滞后于 RN 主线 | 完全自主可控，但所有原生桥（Focus、Remote、AVPlayer）都要自己写 Swift |
| **学习成本** | 低：团队已熟悉 Vue3/TS，只需学 Capacitor 配置与少量 Swift 插件 | 高：需学 Dart、Flutter 渲染模型、新工程结构 | 中高：需学 RN + tvOS fork 用法，且与现有 Vue 技术栈割裂 | 中：SwiftUI/WKWebView 需学，但 JS 侧改动小 |
| **维护成本** | **低**：跟随 Capacitor 官方升级，一套代码出 iOS/tvOS/Android/Web | 高：Flutter 版本升级频繁，tvOS embedder 需跟进 | 中：react-native-tvos 需跟随 RN 主线 rebase，社区 fork 维护节奏不可控 | 高：原生壳代码全部自研，苹果系统升级需自己跟进 |
| **IPA 体积** | 小：壳仅含 WKWebView + Capacitor runtime，约 10–20MB 起步 | 大：Flutter engine 二进制约 20–40MB | 中：RN 框架 + JSCore/Hermes 约 15–30MB | 最小：仅 SwiftUI 壳 + WKWebView，约 5–10MB |
| **性能** | WebView 渲染，音频走原生 AVPlayer 后性能可接受；复杂动画/长列表需优化 | **高**：自绘引擎，60/120fps 稳定 | 高：原生组件渲染 | 中：与 Capacitor 相当，但桥需自己调优 |
| **改造工作量** | **最小**（本文方案） | 最大 | 大 | 中（壳要自己写） |

### 1.2 推荐结论

**推荐路径：Capacitor 6 + 官方 `@capacitor/tvos`。**

理由：

1. **改造量最小**：`src/renderer/` 下的 Vue3 组件、Pinia store、路由、i18n、在线插件（netease/kugou/emby/jellyfin/navidrome）几乎零改动复用，只替换 `window.mainApi` 这条 IPC 边界。
2. **官方 tvOS target**：`@capacitor/tvos` 由 Ionic 官方维护 tvOS platform，无需维护社区 fork（避免 react-native-tvos 那种跟随主线 rebase 的风险）。
3. **生态匹配**：现有技术栈是 TypeScript + Vite，Capacitor 同样基于 Vite/webDir 静态产物，`vite build` → `npx cap sync tvos` 链路天然契合。
4. **裁剪边界清晰**：Electron 专属能力（better-sqlite3、piscina、electron-store、tray、mpris、localMusicScanner、taglib、cueParser）全部收敛在 `src/main/` 与 renderer 的 `window.mainApi` 调用点上，tvOS 侧只需在这些边界做条件编译。
5. **IPA 体积与性能平衡**：相比 Flutter/RN 重写，不引入新的渲染引擎；音频播放后续可通过原生 AVPlayer plugin 替代 Web Audio，性能瓶颈可控。

> SwiftUI 壳 + WKWebView 方案看似复用率高，但 Focus Engine、Siri Remote 手势、后台音频、AVPlayer 桥全部要手写 Swift，长期维护成本反而高于使用官方 Capacitor tvOS target，故不推荐。

---

## 2. Capacitor 集成方案

### 2.1 package.json 新增依赖

在 `package.json` 中新增（packageManager 保持 `yarn@1.22.22`，Node >= 22.6.0）：

```jsonc
{
  "dependencies": {
    "@capacitor/core": "^6.2.0"
  },
  "devDependencies": {
    "@capacitor/cli": "^6.2.0",
    "@capacitor/ios": "^6.2.0",
    "@capacitor/tvos": "^6.0.0"   // tvOS platform，版本跟随 6.x 线
  }
}
```

版本建议：
- `@capacitor/core` / `cli` / `ios` 统一锁在 `^6.2.x`（Capacitor 6 主线，与 Vite 5/Vue3 兼容）。
- `@capacitor/tvos` 使用 6.x 最新预发布/稳定版；接入前先在 Mac 上 `npx cap telemetry off` 并确认其 README 中标注的 tvOS 最低系统要求（tvOS 27 远高于其最低要求）。
- 后续原生能力按需追加 plugin，例如：
  - `@capacitor/preferences`（替换 electron-store）
  - `@capacitor/filesystem`（仅用于应用沙箱内缓存，**不能**访问系统媒体库）
  - 自写 `AVPlayer` plugin（替代 Web Audio 播放管线，见 2.5.1）
  - `@capacitor/status-bar` / `@capacitor/splash-screen`（tvOS 上多为空实现，按需）

安装命令（在 Mac 上执行）：

```powershell
# Windows 本地仅装 JS 依赖；原生工程生成必须在 Mac 上
yarn add @capacitor/core@^6.2.0
yarn add -D @capacitor/cli@^6.2.0 @capacitor/ios@^6.2.0 @capacitor/tvos@^6.0.0
```

### 2.2 `capacitor.config.ts` 配置

在项目根目录新建 `capacitor.config.ts`：

```typescript
import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.klzbw.momomusic',          // tvOS Bundle Identifier，需与 Apple Developer 账号一致
  appName: 'momoMusic',                  // Apple TV 首页显示名
  webDir: 'dist',                        // vite build 产物目录
  backgroundColor: '#000000',            // tvOS 纯黑背景，避免白闪
  ios: {
    // 同时供 iOS 与 tvOS 复用；tvOS 专属项在 tvOS 段覆盖
    contentInset: 'always',
    limitsNavigationsToAppBoundDomains: true,
    allowsLinkPreview: false
  },
  tvos: {
    appId: 'com.klzbw.momomusic',
    appName: 'momoMusic',
    webDir: 'dist',
    // tvOS 专属：禁用双击 home 预览截屏保护、开启后台音频能力声明
    scheme: 'momomusic',
    minimizedParams: {}
  },
  plugins: {
    // 后续原生插件配置放这里
    Preferences: {
      group: 'momoMusic'
    }
  }
};

export default config;
```

关键说明：
- `appId` 必须与 Apple Developer 后台的 Bundle Identifier 完全一致，否则侧载/上架会签名失败。
- `webDir: 'dist'` 与现有 `vite.config.ts` 的构建输出对齐；若当前 renderer 产物目录不同，改为实际目录。
- 后台音频需在 `tvos/App/App/Info.plist` 中声明 `UIBackgroundModes = audio`（见第 5 节）。

### 2.3 `npx cap add tvos` 后的目录结构

在 Mac 项目根目录执行 `npx cap add tvos` 后，会生成（与现有 Electron 工程并存，互不影响）：

```
VutronMusic-main/
├── src/
│   ├── main/                  # Electron 主进程（tvOS 不参与构建）
│   └── renderer/              # Vue3 渲染层（tvOS 直接复用）
├── dist/                      # vite build 产物 → cap sync 拷贝到原生工程
├── android/                   # 已有或后续
├── ios/                       # npx cap add ios 生成（iPhone/iPad 壳）
├── tvos/                      # npx cap add tvos 生成（Apple TV 壳）
│   └── App/
│       ├── App/
│       │   ├── AppDelegate.swift
│       │   ├── Info.plist          # 需改 UIBackgroundModes、支持横屏
│       │   ├── public/
│       │   │   └── …               # 从 webDir sync 进来的静态资源
│       │   └── capacitor.config.json
│       ├── App.xcodeproj/
│       └── Podfile
├── docs/
│   └── tvos-porting.md        # 本文档
├── capacitor.config.ts
├── electron-builder.yml       # 桌面端构建（保持不动）
└── package.json
```

注意：Capacitor 的 tvOS platform 实际生成的目录名通常为 `ios/` 并在 Xcode 内同时挂 iOS + tvOS 两个 target；若 `@capacitor/tvos` 按官方 README 生成独立 `tvos/` 目录，则以上述独立目录为准。接入时以 `npx cap add tvos` 实际输出为准，并回写本节。

### 2.4 构建流程

```powershell
# 1. Web 产物构建（Windows/Mac 均可）
yarn vite build

# 2. 同步 web 产物 + Capacitor 插件到 tvOS 工程（必须在 Mac 上）
npx cap sync tvos

# 3. 用 Xcode 命令行构建未签名 IPA（Mac 上）
cd tvos/App
xcodebuild -project App.xcodeproj \
  -scheme App \
  -destination 'generic/platform=tvOS' \
  -configuration Release \
  -derivedDataPath build
```

GitHub Actions 侧可新增 `.github/workflows/build-tvos.yml`（macOS runner），跑同样三步；Windows 本地**无法**执行第 2、3 步（无 Xcode），只能做 `vite build` + TypeScript 类型检查。

### 2.5 需要 tvOS 条件编译的 renderer 代码

所有 tvOS 专属分支用运行时探测，避免改动桌面端：

```typescript
// src/renderer/shared/platform.ts（新增）
export const isTvOS =
  (window as any).capacitor?.platform === 'tvos';
export const isElectron =
  navigator.userAgent.toLowerCase().includes('electron');
```

以下位置必须按 `isTvOS` 做分支：

#### 2.5.1 Web Audio API 降级（`src/renderer/…/audioEngine.ts`、`convolver.ts`、SoundTouchJS）

tvOS WebKit 限制：
- `AudioContext` 必须在用户手势回调里 `resume()`，且**不允许**在音频未播放时启动（否则静默失败）。
- `ConvolverNode`（混响脉冲响应）在 tvOS WebKit 上行为不稳定，部分系统版本直接抛 `NotSupportedError`。
- 采样率上限受系统限制，SoundTouchJS 的实时变调/变速在 Web Audio 图里会显著掉帧。

降级方案：
- **播放管线整体下沉到原生 AVPlayer plugin**：在 Capacitor tvOS 工程里自写一个 `NativePlayer` plugin，暴露 `play(url)/pause/seek/setVolume/setRate`；renderer 侧 `audioEngine.ts` 检测 `isTvOS` 时跳过 `AudioContext`/`MediaElementSource` 节点图，直接调用该 plugin。
- **音效（混响、均衡器、变调）**：tvOS 上默认关闭 UI 入口；若后续要做，用原生 `AVAudioEngine` 在 plugin 侧实现，**不要**继续走 Web Audio。
- SoundTouchJS 在 `isTvOS` 下直接不加载（动态 `import()` 分支），变调/变速控件置灰。

#### 2.5.2 本地文件功能隐藏

以下模块在 `isTvOS` 时整条路由/菜单不注册：
- `localMusicScanner`（本地音乐扫描）：tvOS 无文件系统访问，且 iOS/tvOS 不暴露系统媒体库给第三方 webview。
- CUE 分轨解析（`cueParser`）：依赖本地 `.cue` + 本地音频文件，整体裁剪。
- taglib 元数据写入（`taglib-wasm` / `music-metadata` 的写路径）：tvOS 沙箱不允许写系统媒体库，读路径也无意义，整体裁剪。

UI 侧：侧边栏"本地音乐"入口、导入本地文件夹按钮、文件选择对话框，全部 `v-if="!isTvOS"`。

#### 2.5.3 插件系统降级为纯在线

插件注册表（`src/renderer/plugins/` 下）按平台过滤：

| 插件 | 桌面 | tvOS |
|---|---|---|
| netease | 保留 | **保留**（纯 HTTPS API） |
| kugou | 保留 | **保留** |
| emby | 保留 | **保留**（走 HTTP API + 直链播放） |
| jellyfin | 保留 | **保留** |
| navidrome | 保留 | **保留** |
| local | 保留 | **移除**（注册表里过滤掉） |

在线插件本身是 fetch 调用，无需改动；只需在插件枚举/类型里把 `local` 标记为 `unsupportedPlatforms: ['tvos']`。

#### 2.5.4 IPC 层替换（`window.mainApi`）

现状：renderer 通过 `window.mainApi.xxx()` 调主进程。tvOS 上没有主进程，需替换为：

1. **纯在线能力**（搜索、歌词、评论、歌单）：直接在 renderer 里 `fetch()` 在线 API，删掉 `window.mainApi` 调用点，或在 `isTvOS` 分支内实现同名函数（直接 fetch）。
2. **本地缓存/偏好**：见 2.5.5 / 2.5.6。
3. **音频播放**：见 2.5.1，走 `NativePlayer` Capacitor plugin。

建议在 `src/renderer/shared/mainApi.ts` 做一个 facade：

```typescript
// 伪代码
export const mainApi = isTvOS
  ? createTvOsMainApi()   // 内部：在线 fetch + Capacitor Preferences + NativePlayer
  : window.mainApi;       // 桌面端原样
```

这样组件层 `mainApi.xxx()` 调用点几乎不用改。

#### 2.5.5 better-sqlite3 → IndexedDB（dexie 已有）

现状：主进程用 better-sqlite3 存本地库；renderer 已有 dexie（IndexedDB）。
tvOS 方案：
- 所有"本地数据库"语义迁移到现有 dexie 实例：歌单、收藏、播放历史、设置，全部落 IndexedDB。
- tvOS 沙箱会在系统清理时回收 IndexedDB，重要配置同时写一份到 Capacitor Preferences（见下）做兜底。
- `isTvOS` 下不再 import better-sqlite3 相关代码（这些本就住在 `src/main/`，天然不参与 web 产物构建，确认 vite build 不打包即可）。

#### 2.5.6 electron-store → Capacitor Preferences

现状：`electron-store` 存 JSON 配置。
tvOS 方案：
- 用 `@capacitor/preferences`，API 风格近似（`get/set/delete`）。
- 在 facade 里统一封装：

```typescript
import { Preferences } from '@capacitor/preferences';
export const store = isTvOS
  ? { get: k => Preferences.get({key:k}), set:(k,v)=>Preferences.set({key:k,value:String(v)}) }
  : electronStoreAdapter;
```

#### 2.5.7 piscina Worker 线程移除

现状：主进程用 piscina 跑 Worker（如封面哈希、批量标签处理）。
tvOS 方案：
- tvOS WKWebView **不支持 Node Worker**，piscina 无法运行。
- renderer 侧如果用到 `new Worker()`，在 `isTvOS` 分支改为主线程执行（小数据量可接受），或把该任务迁移到在线 API（例如封面取色交给后端）。
- `node-vibrant`（取色）在 tvOS 主线程跑小图没问题；`sharp`（图片处理）依赖原生模块，tvOS 上不可用，改为 `<canvas>` 缩图或在线 CDN 缩略图。

---

## 3. tvOS UI 适配清单

### 3.1 Focus Engine 聚焦导航

tvOS 没有鼠标/触摸，所有交互靠 Focus Engine。改造要点：

- 现有可聚焦元素类型：**按钮（Button）、列表项（ListItem）、卡片（Card）、Tab、菜单项、输入框**。
- 给所有可聚焦元素加 `tabindex="0"` 与统一的 `focus-visible` 样式（放大 1.05–1.1x + 投影高亮），保证 WKWebView 把焦点事件透传到网页。
- 方向键切换：依赖 DOM 默认 tab 序列；复杂网格（如歌单封面墙）用 Capacitor tvOS 提供的 Focus API 或原生 `UIFocusGuide` 在 Swift 侧补一条横向/纵向焦点引导线，避免焦点"卡死"在错误方向。
- 列表页（搜索结果、歌单曲目）务必保证：
  - 每行是一个整体可聚焦 `<div tabindex="0">`，不要把行内按钮单独做成可聚焦点，否则焦点会在同一行"漂移"。
  - 聚焦变化时滚动到可见区：监听 `focusin`，调用 `element.scrollIntoView({block:'center'})`。
- Tab 栏：顶部主 Tab 用原生 `UITabBar` 思路，焦点在 Tab 之间横移；不要做成纵向菜单。

### 3.2 10 英尺安全区与尺寸放大

tvOS 观看距离 3 米左右，所有尺寸按"10 英尺 UI"放大：

| 项 | 桌面端 | tvOS 目标 |
|---|---|---|
| 基础字号 | 14px | **24–32px**（正文 24px，标题 32–40px） |
| 行高 | 1.5 | 1.6–1.8 |
| 按钮最小可点尺寸 | 44×44 pt | **≥ 80×80 pt**（Apple HIG 推荐） |
| 卡片 padding | 12–16px | 24–32px |
| 卡片圆角 | 8px | 20–28pt |
| 列表行高 | 48px | 80–96px |

实现方式：在 `isTvOS` 时给根节点加 `class="tvos-layout"`，CSS 用同名变量整体放大：

```css
.tvos-layout {
  --font-base: 26px;
  --space-md: 24px;
  --hit-min: 80px;
}
```

同时保留 Apple TV 的 **safe area**（顶部/底部系统 UI 遮挡）：在 body 上加 `padding: env(safe-area-inset-top) …`，并在 Xcode 里开启 `ViewControllerBasedStatusBarAppearance` 与自动 safe area 处理。

### 3.3 Siri Remote 手势映射

| Siri Remote 操作 | tvOS 行为 | 前端处理 |
|---|---|---|
| 触控板点击（Click） | 确认/选中当前焦点项 | DOM `click()` 默认即可 |
| 上/下/左/右滑动 | 方向导航 | 由 Focus Engine 处理，无需 JS |
| Menu 键 | 返回上一页 | 监听 Capacitor tvOS 的 hardware back 事件 → `router.back()` |
| Play/Pause 键 | 播放/暂停 | 桥接到 `NativePlayer.toggle()`，同时更新 Pinia 播放状态 |
| 长按触控板 | 更多选项（收藏、下载、查看专辑） | 监听长按事件，弹出上下文菜单（自定义全屏 overlay） |
| 长按 Menu | 回主屏幕（系统行为，无需处理） | — |

> tvOS 上**不要**自绘手势区域；所有导航走系统 Focus，前端只负责"被聚焦时的视觉反馈"和"Menu/Play 键事件订阅"。

### 3.4 横屏强制

- tvOS **只支持横屏**，分辨率 1920×1080（1080p）或 3840×2160（4K）。
- 在 `tvos/App/App/Info.plist` 中：
  - `UISupportedInterfaceOrientations` 只保留 `UIInterfaceOrientationLandscapeLeft` / `UIInterfaceOrientationLandscapeRight`。
  - 删除所有 Portrait 方向。
- renderer 侧 `useMediaQuery('(orientation: portrait)')` 不写死任何竖屏布局；CSS 用 `aspect-ratio: 16/9` 容器约束。

### 3.5 长列表虚拟滚动注意事项

现有长列表（曲目表、搜索结果、评论区）若用虚拟滚动，TV 上特别注意：

- **焦点丢失**：虚拟滚动会回收 DOM 节点；当前被焦点的项若被回收，会导致焦点落到 body。必须在回收前保存 `focusIndex`，在新渲染完成后 `nextTick` 重新 `element.focus()`。
- **滚动性能**：每帧只渲染可见区 ±2 屏；避免在滚动中触发 `onScroll` 里的重量级计算（取色、模糊）。
- **预加载**：焦点项切到第 N 首时，预取 N+1 ~ N+5 的歌词/封面，避免切歌卡顿。
- **滚动条样式**：TV 上隐藏默认滚动条，用"当前位置 / 总数"文字或底部进度条代替。

### 3.6 顶部 Tab 栏与底部播放栏

- **顶部 Tab 栏**：横向通栏，高度放大到 80–96pt；焦点项底部加 4pt 高亮条；不要做下拉折叠。
- **底部播放栏**：固定在 safe area 底部，高度 ≥ 120pt；左侧封面（120×120pt）+ 歌名/歌手；右侧播放/暂停、下一首、歌词按钮。整个播放栏本身**不参与 Tab 序列**，只接受 Play/Pause 键与焦点进入后的左右方向键。
- 不要在 TV 上做"迷你播放器可拖动收起"这类手势。

### 3.7 歌词显示 TV 适配

- 歌词页独立成全屏 route（不是桌面端的右侧抽屉）。
- 字号：当前行 **44–56px**，上下相邻行 24–28px、半透明。
- 居中对齐，行间距 1.8–2.0。
- 自动滚动：用 `requestAnimationFrame` 计算当前时间戳对应的歌词行，`scrollTo` 把当前行固定在屏幕垂直中线。
- 焦点：歌词页本身**不参与 Focus 循环**（否则每句歌词都能聚焦很奇怪），只接受 Menu 键返回与 Play/Pause。
- 背景：取专辑封面主色做高斯模糊背景（`node-vibrant` 在 tvOS 主线程对小图运行）。

---

## 4. 功能裁剪清单

| 功能名 | 桌面版状态 | tvOS 处理 | 原因 |
|---|---|---|---|
| 本地音乐扫描（localMusicScanner） | 保留 | **裁剪** | tvOS 无任意文件系统访问，无法遍历用户音乐目录 |
| CUE 分轨解析（cueParser） | 保留 | **裁剪** | 依赖本地 `.cue` 文件 + 本地音频文件，tvOS 无本地文件 |
| taglib 元数据写入（taglib-wasm） | 保留 | **裁剪** | tvOS 沙箱不允许写系统媒体库文件 |
| 系统托盘（tray） | 保留 | **裁剪** | tvOS 无 tray 概念 |
| 全局快捷键（globalShortcut） | 保留 | **裁剪** | tvOS 无外接键盘快捷键场景，交互走 Siri Remote |
| MPRIS | 保留（Linux） | **裁剪** | Linux 专属 D-Bus 接口 |
| TouchBar | 保留（macOS） | **裁剪** | MacBook Pro 专属硬件 |
| Dock 菜单（dock） | 保留（macOS） | **裁剪** | macOS 专属 |
| 缩略图工具栏（thumBar） | 保留（Windows） | **裁剪** | Windows 专属 |
| Discord Rich Presence | 保留 | **降级** | 可保留，但需自写 Capacitor plugin 桥接 Discord SDK；MVP 阶段先关闭 |
| 在线插件播放（netease/kugou/emby/jellyfin/navidrome） | 保留 | **保留** | 纯 HTTP API，直接可用 |
| 歌词显示 | 保留 | **保留（UI 重排）** | 见 3.7，全屏大字居中 |
| 评论区 | 保留 | **保留** | 纯 DOM 列表，做焦点适配即可 |
| 歌单管理 | 保留 | **保留（存储替换）** | 数据落 IndexedDB(dexie)，不再走 better-sqlite3 |
| 搜索 | 保留 | **保留** | 在线 API；TV 上的键盘用系统 `UITextField`（Capacitor 会自动桥接） |
| 播放控制 | 保留 | **保留（重映射）** | 播放/暂停/上下首映射到 Siri Remote 与原生 AVPlayer |
| 音效 / 均衡器 / 变调 / 变速 | 保留（Web Audio + SoundTouchJS） | **降级** | tvOS WebKit Web Audio 受限；MVP 关闭 UI 入口，后续用原生 `AVAudioEngine` plugin 重做 |
| 桌面歌词 OSD | 保留 | **裁剪** | tvOS 无悬浮窗，歌词改为全屏 route |
| 自动更新（electron-updater） | 保留 | **裁剪** | tvOS 应用通过 App Store 或侧载工具更新，不内嵌更新器 |
| 本地收藏 / 历史 / 设置 | 保留 | **保留（存储替换）** | 迁移到 IndexedDB + Capacitor Preferences |
| 专辑封面取色（node-vibrant） | 保留 | **保留（主线程）** | 取消 Worker 化，小图主线程跑可接受 |
| 图片处理（sharp） | 保留 | **降级** | 原生模块不可用，改为 `<canvas>` 或 CDN 缩略图 |
| Worker 批量任务（piscina） | 保留 | **裁剪** | tvOS WKWebView 不支持 Node Worker，任务改主线程或在线化 |

---

## 5. 已知限制与后续手动步骤

### 5.1 未签名 IPA 的安装限制

- tvOS 不像 Android 那样"开个未知来源就能装 APK"。未签名 IPA 在非越狱 Apple TV 上**无法直接安装**，必须借助：
  - **AltStore / AltServer**：通过电脑周签名，**每 7 天需重签**（免费 Apple ID）或 1 年（付费开发者账号）。
  - **Sideloadly**：同上，7 天重签。
  - **越狱设备**：可任意安装未签名 IPA（不推荐作为分发方式）。
  - **Apple Developer Program（$99/年）**：可用正规证书签名，7 天限制解除，且能上架 App Store TV 区。
- 因此 CI 产物定位为"开发自测包"，不承诺面向终端用户分发。

### 5.2 tvOS WebKit 对 Web Audio API 的具体限制

- `AudioContext` 必须在**用户手势**回调里调用 `resume()`，且在音频未真正播放时启动会被静默挂起。
- `ConvolverNode`（混响）在 tvOS WebKit 上存在兼容性问题，部分版本抛 `NotSupportedError` 或脉冲响应静默失效。
- 采样率受系统限制，自定义 `sampleRate` 构造参数可能被忽略；SoundTouchJS 实时变调/变速在长音频上有掉帧风险。
- 结论：**不要把播放管线押在 Web Audio 上**，按 2.5.1 下沉到原生 AVPlayer。

### 5.3 后台音频

- tvOS **支持**后台音频（App 切到 home 后音乐可继续播）。
- 必须在 `tvos/App/App/Info.plist` 中声明：

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

- 同时在原生 `AVAudioSession` 类别设置为 `playback`，否则锁屏/切后台时系统会挂起音频。

### 5.4 必须在 Mac 上手动执行的步骤

以下步骤**无法在 Windows 本机完成**，必须有一台跑 macOS + Xcode 26+ 的机器：

1. `yarn install` 安装 Capacitor 依赖。
2. `npx cap add tvos`（或按 `@capacitor/tvos` README 的命令）生成 tvOS 原生工程。
3. 用 Xcode 打开 `tvos/App/App.xcodeproj`，在 **Signing & Capabilities** 中选择自己的 Apple Developer Team，设置 **Bundle Identifier** 为 `com.klzbw.momomusic`（与 `capacitor.config.ts` 中 `appId` 一致）。
4. 在项目设置里确认 Deployment Target 为 tvOS 27（或更低的实际支持版本）。
5. 在 `Info.plist` 中：
   - 加 `UIBackgroundModes = audio`；
   - 只保留横屏方向；
   - 关闭 `UIRequiresFullScreen`（tvOS 上无意义）。
6. 自写 `NativePlayer` Swift plugin（AVPlayer 封装），通过 `CAPBridgedPlugin` 暴露给 JS。
7. `xcodebuild` 构建后用 Xcode → Window → Devices and Simulators 把 IPA 拖到已通过 USB 配对的 Apple TV 上，或用 AltServer 侧载。

### 5.5 Windows 本地与 GitHub Actions 的限制

- **Windows 本地无法运行 `npx cap sync tvos` / `xcodebuild`**：这两步依赖 Xcode。Windows 侧只能做：
  - `yarn vite build` 验证 web 产物；
  - `tsc --noEmit` 跑类型检查（把 `isTvOS` 分支都纳入检查）；
  - `eslint` / `vitest` 跑单元测试。
- **GitHub Actions**：必须用 `macos-latest` runner 才能构建 tvOS IPA；但即使构建成功，**也只能产出未签名或用 secrets 中证书签名的 IPA**，无法在 Windows 本地"验证装到真机"。真机验证仍需在 Mac + Apple TV 上做。
- 建议新增 `.github/workflows/build-tvos.yml`，仅做"构建成功 + 上传 IPA artifact"，不做签名分发。

### 5.6 推荐的最小可行版本（MVP）范围

MVP 第一期只做：

1. **在线播放**：netease / kugou / emby / jellyfin / navidrome 任一可用插件 + 原生 AVPlayer 播放。
2. **歌词显示**：全屏歌词页（见 3.7）。
3. **歌单管理**：收藏、播放历史落 IndexedDB(dexie)。
4. **基础导航**：顶部 Tab（推荐/搜索/歌单/我的）+ Siri Remote 方向键 + Menu 返回 + Play/Pause。

后续迭代再加入：评论区、搜索联想、音效（原生 AVAudioEngine）、Discord Rich Presence、Apple Music 风格的全屏 Now Playing 页等。本地音乐、CUE、taglib、托盘/快捷键/Dock/TouchBar/MPRIS/ThumBar 等桌面专属能力**永久不做**。

---

## 附：接入检查清单（Checklist）

- [ ] `package.json` 已加 `@capacitor/core` / `cli` / `ios` / `tvos`，版本统一 6.x。
- [ ] 根目录 `capacitor.config.ts` 写好 `appId` / `webDir` / tvOS 段。
- [ ] Mac 上 `npx cap add tvos` 成功，Xcode 能打开工程。
- [ ] `src/renderer/shared/platform.ts` 提供 `isTvOS` 运行时判断。
- [ ] `audioEngine.ts` / `convolver.ts` / SoundTouchJS 在 `isTvOS` 分支下沉到 `NativePlayer` plugin。
- [ ] 本地音乐/CUE/taglib 入口在 UI 层 `v-if="!isTvOS"` 隐藏。
- [ ] 插件注册表过滤掉 `local` 插件。
- [ ] `window.mainApi` 替换为 facade（在线 fetch + Capacitor Preferences + NativePlayer）。
- [ ] electron-store 替换为 `@capacitor/preferences`。
- [ ] piscina Worker 路径在 tvOS 下不加载。
- [ ] 可聚焦元素统一 `focus-visible` 样式 + 方向键滚动到可见。
- [ ] 字号/间距/按钮尺寸按 3.2 表放大。
- [ ] Info.plist：`UIBackgroundModes=audio`，仅横屏。
- [ ] `xcodebuild` 能产出 Release IPA（未签名）。
- [ ] MVP：在线播放 + 歌词 + 歌单 在真机 Apple TV 上跑通。
