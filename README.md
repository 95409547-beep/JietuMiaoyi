# 截图秒译 (JietuMiaoyi)

<p align="center">
  <strong>专为 macOS 原生打造的免费开源「框选即原位覆盖翻译」桌面工具</strong><br>
  零配置 · 免语言包 · 免 API Key · 0.6 秒极速原位秒译中文 · Apple Silicon & Intel 通用
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/macOS-14.0%2B-007AFF?style=flat-square&logo=apple">
  <img alt="Arch" src="https://img.shields.io/badge/Architecture-Universal%20(arm64%20%2B%20x86__64)-34C759?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-blue?style=flat-square">
</p>

---

## 核心亮点

- **真正的「原位覆盖替换」体验**  
  框选屏幕任意区域（网页、PDF 论文、外文软件界面、设计稿、游戏画面），自动对边缘背景像素进行中位数采样，用双层羽化色块无痕擦除原文，并在**原屏幕坐标位置**直接排版显示中文，标题与正文自动匹配苹方粗细字重。

- **0.6 秒极速响应，开箱即用永不罢工**  
  - **本地极速识别**：基于苹果原生 `Vision` 框架毫秒级离线文字识别（`~0.18s` 冷启动）与自然段落智能聚合算法，同时支持切换深度多语识别模式。
  - **多路并发竞速翻译**：内置腾讯交互翻译（国内强制直连原生批量接口，`~0.4s` 极速返回）与 Google 多节点并发竞速及自动降级引擎，**无需下载庞大离线语言包、无需申请任何 API Key**。

- **像素级打磨的 macOS 原生高颜值 UI**  
  - **精简菜单栏图标**：状态栏仅保留一枚纯单色矢量模板图标（圆角取景框 + 光学居中「文」字），完美随系统深浅色模式自动切换。
  - **丝滑框选交互**：`ScreenCaptureKit` 瞬间定格高清画面，配备十字导引线、双层高光描边、四角圆点手柄与实时尺寸胶囊。
  - **黑晶磨砂胶囊工具条**：覆盖层右上角悬浮原生毛玻璃工具条（统一等线宽矢量几何图标 + 中文标签：**`原文` · `复制` · `穿透` | `关闭`**），基于 CoreText 像素墨迹包围盒严格居中，鼠标移开自动柔和淡化至半透明，绝不遮挡阅读视线。
  - **原生系统设置风格面板**：支持自定义全局快捷键、目标语言、识别引擎，并提供独立的 **「开机自启」** 与 **「菜单栏常驻」** 拨动开关。

---

## 安装与使用

### 方式一：通过 `.dmg` 安装包直接安装（推荐）

1. 前往 [GitHub Releases](https://github.com/95409547-beep/JietuMiaoyi/releases/latest) 下载最新的 `截图秒译-v2.0.0-macOS.dmg`（Apple Silicon 与 Intel 双架构通用安装包）。
2. 双击挂载镜像，将 **「截图秒译.app」** 拖入右侧 **「Applications（应用程序）」** 文件夹。
3. 首次打开若提示「无法验证开发者」，可在终端执行以下命令一键解除隔离属性（或在「系统设置 → 隐私与安全性」底部点击「仍要打开」）：
   ```bash
   xattr -cr /Applications/截图秒译.app
   ```
4. 首次框选时，按系统提示在「系统设置 → 隐私与安全性 → 录屏与系统录音」中开启 **「截图秒译」** 开关即可（全局快捷键基于 Carbon 事件接口，**无需**辅助功能权限）。

### 方式二：从源码一键编译安装

环境要求：macOS 14.0 (Sonoma) 及以上，已安装 Xcode Command Line Tools（`xcode-select --install`）。

```bash
# 1. 克隆仓库
git clone https://github.com/95409547-beep/JietuMiaoyi.git
cd JietuMiaoyi

# 2. 一键编译并安装至 /Applications/截图秒译.app
chmod +x build_and_install.sh
./build_and_install.sh

# （可选）打包生成 Universal 通用 .dmg 安装镜像
chmod +x package_dmg.sh
./package_dmg.sh
```

---

## 快捷键与操作指南

| 操作 | 默认方式 | 说明 |
| :--- | :--- | :--- |
| **触发截图秒译** | `Option + S`（`⌥S`） | 全局随时呼出框选（可在偏好设置中修改为 `⌥A`、`⌥D`、`⌘⇧2` 等） |
| **取消框选 / 关闭覆盖层** | `ESC` 键 或 点击 `关闭` | 退出当前截图或清除屏幕上的翻译覆盖层 |
| **对比查看原文** | 点击工具条 `原文` | 在原位置一键切换显示「中文译文 / 原始画面」 |
| **复制识别与译文** | 点击工具条 `复制` | 将全部译文一键复制至系统剪贴板 |
| **鼠标点击穿透** | 点击工具条 `穿透` | 保持译文悬浮在屏幕上的同时，鼠标可直接穿透操作下层窗口 |

---

## 项目结构

```text
.
├── Sources/
│   ├── AppMain.swift                 # 应用入口、单色矢量菜单栏图标与生命周期管理
│   ├── HotKeyManager.swift           # Carbon 全局热键注册与管理（免辅助功能权限）
│   ├── ScreenCaptureSelection.swift  # ScreenCaptureKit 屏幕定格与高颜值选区交互窗口
│   ├── OCRAndParagraphEngine.swift   # Vision 毫秒级 OCR 识别与自然段落智能合并引擎
│   ├── MultiSourceTranslator.swift   # 腾讯交互直连 + Google 多源并发竞速翻译引擎
│   ├── InPlaceOverlayWindow.swift    # 背景像素采样无痕擦除、自适应排版与磨砂胶囊工具条
│   └── SettingsWindow.swift          # 原生 Auto Layout 偏好设置面板与开机自启管理
├── build_and_install.sh              # 本地一键构建图标、签名并安装至 /Applications
├── package_dmg.sh                    # 构建 arm64 + x86_64 通用二进制并打包标准 .dmg 安装包
└── LICENSE                           # MIT 开源许可证
```

---

## 开源协议

本项目基于 [MIT License](LICENSE) 免费开源，欢迎自由使用、修改与分享。
