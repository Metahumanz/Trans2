# <img src="docs/icon.png" width="88" alt="Trans2 图标"> Trans2

**Trans2 = Transcribe + Translation。**

本地转写，AI 翻译，一条流水线。把音视频或字幕丢进来，得到一份可以直接用的双语字幕。

[下载最新版](https://github.com/Metahumanz/Trans2/releases) · [更新日志](CHANGELOG.md) · [GPLv3](LICENSE)

```
音视频 ──afconvert──▶ whisper.cpp ──▶ SRT ──▶ OpenAI 兼容 API / Ollama ──▶ 双语 SRT
                                          ▲
                                  已有 .srt 直接进入翻译
```

转写全程在本机完成；只有翻译这一步会把字幕文本发送到你选择的模型服务。

## 为什么叫 Trans2

**Transcribe + Translate**，两个 T，两个阶段：

1. **Transcribe**：whisper.cpp 在 Apple Silicon 上本地转写，支持 Metal，可选 Core ML / ANE encoder；
2. **Translate**：把转写出的 SRT（或你已有的 SRT）交给 AI 翻译，默认输出「译文在上、原文在下」的双语字幕。

它不是云端转写工具，也不是只能翻译字幕的脚本——它把两件事接成了一条可批量、可暂停、可检查的流水线。

## 功能

- **一条队列，两种输入**：音视频走「转写 → 翻译」，`.srt` 直接走「翻译」，也可以混在一起。
- **本地转写**：whisper.cpp + Metal；可选 Core ML / ANE encoder；批量、实时文本、VAD、TXT/SRT/VTT/JSON 导出。
- **AI 翻译**：任意 OpenAI 兼容接口或本地 Ollama；目标语言中文 / 英文 / 日文 / 韩文；可开关「模型润色」。
- **两种翻译时机**：
  - **全部转写完成后**：整批转写结束，再统一翻译，适合先检查原文；
  - **边转写边翻译**：每转完一个文件就开始翻译，同时继续转写下一个，批量任务总耗时更短。
- **双语字幕**：默认输出 `xxx.<lang>.srt`，译文在上、原文在下；也可以只输出译文。
- **提供商管理**：预设、增删改、切换、连通性测试；密钥保存在本机 `secrets.json`（0600），不写进 `providers.json`。
- **从 AItrans 一键导入**：首次启动自动读取 `~/Library/Application Support/AITrans/` 里的提供商与密钥，不用重填 Key。
- **沿用 WhisperMac 的运行时**：优先复用 `~/Library/Application Support/WhisperMac/` 里已有的 whisper-cli、模型、Core ML encoder 和 Silero VAD 模型，不重复下载 1.5 GB。
- **应用内检查更新**：启动时可选自动检查 GitHub Releases；发现新版本可下载 dmg/zip 或打开发布页。
- **三语界面**：English / 简体中文 / 日本語，跟随系统或手动切换。

## 界面

窗口按操作顺序分成四块：

- **左侧任务轨**：队列在上，常用任务设置在下（翻译开关、目标语言、提供商、翻译时机）；
- **中间工作区**：显示「本次任务」和「将生成」的文件；运行时显示实时字幕；结束后显示 SRT 预览和全部输出；
- **设置窗口**：按「通用 / 转写 / 翻译 / 输出 / 提供商 / 模型与运行时」分页签，路径、提供商、并发等一次性配置都在这里；
- **底部动作栏**：状态 + 开始 / 停止 / 新建任务。

![任务设置与输出预览](docs/screenshots/setup.png)

![完成后的字幕预览与输出文件](docs/screenshots/result.png)

![翻译设置页签](docs/screenshots/settings.png)

![软件更新](docs/screenshots/updates.png)

## 安装

### 使用发布版

1. 从 [Releases](https://github.com/Metahumanz/Trans2/releases) 下载最新的 `Trans2-<version>-arm64.dmg`；
2. 打开 dmg，把 `Trans2.app` 拖进「应用程序」；
3. 首次启动如果被 macOS 拦截：右键 `Trans2.app` →「打开」，或执行：

   ```sh
   xattr -cr /Applications/Trans2.app
   ```

4. 首次启动如果缺少模型，按提示在应用内下载，或在「设置 → 模型与运行时」指向已有的 `ggml` 模型。

### 从源码构建

```sh
# 一次性准备 whisper.cpp 运行时（Metal + CoreML）
brew install cmake python@3.11
./Scripts/setup-whispercpp.sh

# 跑测试
swift test --disable-sandbox

# 产出 dist/Trans2.app、zip 与 dmg
./Scripts/package-app.sh "$(cat VERSION)"
```

日常调试用 `./make-app.sh` 生成仓库根目录的 `Trans2.app`；直接 `swift run` 也可以，但资源包与运行时路径以 `.app` 为准。

> 本机 SwiftPM 的 sandbox 在部分环境不可用，脚本统一加了 `--disable-sandbox`。

## 快速开始

1. 拖入音视频或 `.srt` 文件（可拖文件夹，递归扫描）。
2. 在左侧「字幕翻译」打开开关，选择目标语言、提供商和翻译时机。
   - 提供商右侧的按钮可以管理接口、模型和 API Key，或从 AItrans 导入；
   - 展开「更多翻译选项」可切换双语 / 仅译文、是否润色；
   - 「转写」「输出」的详细设置在设置窗口对应页签。
3. 点右下角「开始转写并翻译」。

### 输出

默认写在源文件旁边：

| 输入 | 产物 |
| --- | --- |
| `movie.mp4` | `movie.txt`、`movie.srt`、`movie.zh.srt` |
| `existing.srt` | `existing.zh.srt`（设置了统一输出目录时写到那里） |

- `movie.srt` 是 whisper 原文，`movie.zh.srt` 是翻译结果（默认双语）。
- 翻译失败不会丢掉转写结果：失败写进日志，结果页会提示失败段数。
- 只放 `.srt` 时不需要 whisper-cli 或模型。

## 翻译时机怎么选

| 模式 | 行为 | 适合 |
| --- | --- | --- |
| 全部转写完成后 | 整批转写结束，再逐个文件翻译 | 想先检查转写质量；单文件任务 |
| 边转写边翻译 | 每完成一个文件就翻译，同时转写下一个 | 批量任务，想缩短总耗时 |

「边转写边翻译」是**按文件**的流水线：单个文件仍要等它自己转写完成；批量时文件之间的转写和翻译会重叠。API 模式最多同时翻译 2 个文件，Ollama 模式 1 个，避免请求过载。

## 数据与隐私

| 内容 | 路径 |
| --- | --- |
| 提供商 / 翻译设置 | `~/Library/Application Support/Trans2/providers.json`、`settings.json` |
| API Key | `~/Library/Application Support/Trans2/secrets.json`（明文，0600） |
| 下载的模型 / encoder | `~/Library/Application Support/Trans2/runtime/` |
| 运行日志（含字幕内容） | `~/Library/Logs/Trans2/` |
| 转写历史 | `~/Library/Application Support/Trans2/history.json` |

- 音频、视频和转写结果不会上传；
- 开启翻译时，只有字幕文本会发送到你选择的 API / Ollama；
- 密钥和日志都在本机，建议保护用户目录权限。

## 项目结构

```
Trans2/
├─ Sources/TransCore/     翻译内核（SRT、提示词、提供商、重试、润色）
│  └─ Generated/Spec.swift  由 spec/ 生成，勿手改
├─ Sources/Trans2/        SwiftUI 应用 + 转写流水线 + 翻译阶段
├─ Tests/TransCoreTests/  翻译内核单测（含 AItrans 黄金样本）
├─ Tests/Trans2Tests/     应用、路径、队列、端到端测试
├─ spec/                  提示词与预设的唯一事实来源
├─ tools/gen_spec.py      从 spec/ 生成 TransCore/Generated/Spec.swift
├─ tools/gen_icon.py      生成应用图标（docs/icon.png 与 AppIcon.icns）
├─ fixtures/              来自 AItrans 的 SRT 编码 / 解析黄金样本
├─ .github/workflows/     tag 触发的打包与 Release 流程
├─ CHANGELOG.md           已发布版本的更新日志
└─ Scripts/               打包、changelog 与 whisper.cpp 构建脚本
```

## 测试

```sh
# 单元测试
swift test --disable-sandbox

# 端到端：真实 say 语音 + 真实 whisper-cli + 本地 mock 翻译服务
python3 Scripts/mock-openai-server.py &
TRANS2_E2E=1 swift test --disable-sandbox --filter AppModelPipelineTests
```

端到端覆盖：`say` 语音 → `afconvert` → `whisper-cli` → 翻译 HTTP → 双语 SRT → 预览；纯 `.srt` 队列跳过 whisper；以及「边转写边翻译」的双文件流水线。

## 发布与更新日志

版本号写在 [VERSION](VERSION)。推送 `v*` tag 会触发
[.github/workflows/release.yml](.github/workflows/release.yml)：

```sh
# 先确认 VERSION 与 tag 一致
git tag v0.3.1
git push origin main --tags
```

工作流会：

1. 在 Apple Silicon macOS runner 上跑 `swift test`；
2. 构建 whisper.cpp 运行时，打包 `Trans2.app`、zip 和 dmg；
3. 用 [Scripts/changelog.py](Scripts/changelog.py) 按 conventional commits 生成更新日志；
4. 创建 GitHub Release，上传 dmg / zip，并附带安装说明。

也可以在 Actions 页面手动 `workflow_dispatch`，输入版本号（必须与 `VERSION` 一致）。
[CHANGELOG.md](CHANGELOG.md) 记录已发布版本；应用内「检查更新」读取 GitHub 的 latest release。

## 已知限制

- 仅 macOS / Apple Silicon；Windows 版本尚未开始。
- 不是字幕编辑器：没有时间轴拖动、逐句校对界面。
- 发布产物为 ad-hoc 签名，首次打开需右键「打开」或 `xattr -cr`。
- 翻译会消耗所选服务的额度；密钥以明文保存在本机文件，请自行保护用户目录。
- 同一次批量里若两个同名 `.srt` 指向同一个统一输出目录，后一个会覆盖前一个。
- 「边转写边翻译」是按文件流水线，不是逐句实时翻译。

## 来源与许可

- **Trans2 本身以 GNU General Public License v3.0 or later 发布**，完整文本见 [LICENSE](LICENSE)。
- 转写壳与 whisper.cpp 集成来自 **WhisperMac**（MIT）。
- 翻译提示词、提供商存储与润色流水线来自作者自己的 **AItrans**。
- whisper.cpp 为 MIT；Silero VAD 模型按需下载。
- 第三方组件保留各自许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

GPLv3 允许你运行、研究、修改和再分发 Trans2；再分发修改版时需要保留同样的自由，并提供对应源代码。
