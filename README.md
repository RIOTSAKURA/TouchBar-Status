# TouchBarAgentStatus

一个原生 Swift 编写的 macOS 菜单栏应用，用于在 MacBook Touch Bar 上实时显示 [opencode](https://opencode.ai) agent 的工作状态（thinking / writing / running tool / idle）。

## 项目简介

TouchBarAgentStatus 是一个零依赖的单文件 Swift 程序（`main.swift`），通过只读轮询 opencode 的本地 SQLite 数据库获取 agent 当前的工作状态。状态显示在 Touch Bar 的 **App 区域**（居中主区域），系统 Control Strip（亮度/音量/Siri）和 Esc 键保留不受影响，同时镜像到 macOS 菜单栏。

## 功能特性

- Touch Bar App 区域实时状态（白色加粗大字，各状态图标不同）：
  - `🔧 BASH · git status ⠋` — 正在运行工具（工具名 + 输入命令/路径摘要）
  - `✍️ writing · 最近输出首行 ⠋` — 正在输出文本（附最近文本片段）
  - `🧠 thinking ⠋` — 正在推理
  - `💤 · 会话标题` — 无近期活动
- 自渲染 `esc` 按钮（点击注入真实 escape 键码，与物理键等效）
- 系统控件零干扰：Control Strip（亮度/音量等）完整保留
- Control Strip 常驻托盘小图标（随状态切换 💤/✍️/🧠/🔧/⚠️），状态条被系统收回时点击可恢复
- 菜单栏镜像显示，点击可查看完整状态、手动刷新（⌘R）、退出
- 无 Dock 图标，后台常驻，每 2s 轮询数据库 + 每 0.5s 刷新动画

## 工作原理

- **数据源**：`~/.local/share/opencode/opencode.db`（SQLite，只读模式打开，WAL 模式下并发读安全，无需 `opencode serve`）
- **状态判定**：取最近活跃 session，扫描最近 30 个 part：
  - `type=="tool" && state.status=="running"`（180s 有效期）→ 显示工具名 + `state.input` 中的命令/路径摘要
  - 最近 10s 内有 text / reasoning 输出 → `writing`（附最近文本首行）/ `thinking`
  - 否则 → `idle`（显示会话标题）
- **Touch Bar 显示**（MTMR 同款技术）：
  - `NSTouchBarItem.addSystemTrayItem` 注册托盘图标（经 ObjC runtime IMP 直调，新版 SDK 已删除声明）
  - `NSTouchBar.presentSystemModalTouchBar(placement: 0)` 呈现状态条到 App 区域
  - `DFRFoundation` 私有框架：托盘图标可见性 + 关闭 close box
  - 每 2s 轮询时重新断言呈现，防止系统因切换前台应用收回

## 项目结构

```
TouchBar-Status/
├── main.swift     # 全部实现：数据库轮询 + 状态模型 + Touch Bar/菜单栏 UI
├── Makefile       # 构建 / 运行 / LaunchAgent 安装（安装到 ~/Library/Application Support）
└── README.md
```

## 环境要求

- 带 Touch Bar 的 MacBook（Intel 2016-2020 机型；无 Touch Bar 时仅菜单栏可见）
- macOS 15（Sequoia，已验证；依赖的私有 API 在更新版本中可能移除）
- Xcode Command Line Tools（编译需要）
- 已安装并使用过 opencode（存在 `~/.local/share/opencode/opencode.db`）

## 使用

```bash
make build          # 编译
make once           # 自检：打印一次当前状态后退出
make run            # 前台运行
make install-agent  # 安装二进制到 ~/Library/Application Support 并注册 LaunchAgent，开机自启
make uninstall-agent
```

> 注意：必须通过 `make install-agent` 以 launchd 方式运行；二进制需放在 `~/Library/Application Support/` 下（`~/Documents` 受 TCC 保护，launchd 进程打开会被阻塞）。

## 配置

| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `OPENCODE_DB` | `~/.local/share/opencode/opencode.db` | 覆盖 opencode 数据库路径 |
| `TBAS_PLACEMENT` | `0` | Touch Bar 呈现位置：`0`=App 区域（推荐）、`1`=全宽接管（顶掉系统控件） |

调试日志：`/tmp/tbas-debug.log`。

## 已知限制

- 触控栏呈现依赖私有 API（`DFRFoundation` + AppKit 未公开类方法），macOS 大版本更新后可能失效
- `TBAS_PLACEMENT` 取 2-5 时 `presentSystemModalTouchBar` 会永久阻塞（内部枚举值未知），仅 0/1 可用
- "正在工作"的判定基于数据库最近写入时间（10s 窗口）+ 工具 running 状态（180s 有效期），agent 长时间无输出的等待场景（如等待用户授权）可能显示为 idle
- 仅监控最近活跃的一个 session；subagent 运行时显示的是最近更新的那个 session
