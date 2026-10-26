---
name: gui-ops
description: 云桌面/Windows 主机 GUI 自动化（截图、鼠标点击、键盘输入、窗口管理、UIA 控件树读取）。适用于需要操作交互桌面上的原生窗口（如 BilldDesk、安装向导、任意 GUI 程序）的场景。通过常驻 worker（计划任务跑在交互会话）+ 文件队列通信，任何会话里的 agent 都能用 SendInput 真实注入键鼠、用 GDI 截图、用 UI Automation 结构化读取原生窗口控件（对 Flutter/自绘窗口无效，这类窗口请用截图+视觉）。与 file-relay 搭配可把截图传回外部查看。
version: 1.1.0
---

# gui-ops — Windows 交互桌面 GUI 自动化

## 何时使用

- 需要对**原生 GUI 窗口**做截图、点击、输入、窗口激活（浏览器之外的场景，如 Flutter/Win32 应用、安装向导）。
- 当前进程不在交互桌面会话（例如 AgentDock exec 落在 session 0 无桌面）时，本 skill 是桥接通道：worker 常驻交互会话，客户端提交任务即可。
- 不负责：浏览器内网页自动化（用 browser/Playwright 类工具）、进程注入、系统管理。

## 架构

```
任意会话（如 exec 的 session 0）                 交互桌面会话（如 session 2）
scripts/guiops.ps1  ──写命令──>  <Root>\queue\  worker(计划任务 AgentDock-GuiOpsWorker)
       ▲                              │          guiworker.ps1 常驻循环
       └────轮询结果──── <Root>\out\<id>.json ──── SendInput 注入 / GDI 截图 / 窗口 API
```

- 通信根目录 `Root` 默认 `C:\ProgramData\gui-ops`（queue/ out/ status.json worker.log）。
- worker 由安装方用计划任务（Interactive，跑在桌面用户会话）拉起；客户端只要求对 Root 有读写权限。
- 截图用 GDI（RDP 会话断开后桌面停止渲染会得到黑图，需保持会话活动）。
- 点击/输入用 SendInput 真实注入（Flutter 等不吃 PostMessage 合成消息的应用也能响应）。

## 使用方法（客户端 `scripts/guiops.ps1`）

宿主适配（AgentDock）：`exec_command skill=gui-ops` 后 workdir 即 skill 根目录，按相对路径执行：

```
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op screenshot -Out C:\gui-ops-shots\cur.png
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op click -X 960 -Y 540
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op click -X 540 -Y 380 -Button right
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op type -Text "hello world"
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op key -Keys ctrl+shift+esc
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op window -Action list
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op window -Action activate -Title "BilldDesk"
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op uia -Target "Shell_TrayWnd"
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op uia -Target "记事本" -Find "保存"   # 返回"保存"按钮中心坐标
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op scroll -X 960 -Y 540 -Delta -240
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/guiops.ps1 -Op ping -Echo hi
```

非 AgentDock 宿主直接用 `python3` 式相对路径约定调用同一脚本即可。

## 操作一览

| -Op | 必填参数 | 说明 |
|---|---|---|
| screenshot | -Out（可选，指定则复制到该路径） | 全虚拟屏 PNG；结果含 file/width/height/size |
| click | -X -Y [-Button left/right/middle] [-Double] | 移动+单击/双击 |
| move | -X -Y | 仅移动光标 |
| scroll | -X -Y -Delta | 滚轮，-120 为向下滚一格 |
| type | -Text | Unicode 逐字符注入，`\n` 映射为回车 |
| key | -Keys | 组合键，`+` 分隔：ctrl/alt/shift/win/enter/tab/esc/f1-f12/字母/数字 |
| window | -Action list / activate -Title / foreground | 列出可见窗口 / 前置窗口 / 查询前台 |
| uia | -Target [-Find 名字子串] [-Max N] | 只读枚举窗口 UIA 控件树（type/name/value/rect/enabled）。Target = hwnd 数字 \| 精确类名 \| 标题子串。带 -Find 时返回匹配控件中心坐标（可直接喂给 click）。对原生 Win32/WPF/Qt 窗口有效；Flutter/自绘窗口（如 BilldDesk）不暴露语义树，请改用 screenshot+视觉 |
| sleep | -Ms | worker 侧等待（配合连续动作） |
| ping | -Echo | 存活探测 |

通用参数：`-TimeoutSec`（默认 25）、`-Root`（默认 C:\ProgramData\gui-ops）。

输出恒为**一行 JSON**：`{op, ok, ...结果}`；失败含 `error` 与 `message`（可附 `hint`）。

## 典型闭环（配合 file-relay）

1. `guiops.ps1 -Op screenshot -Out C:\ProgramData\gui-ops\out\cur.png`
2. `file-relay` push 该 PNG → 外部拉取后用视觉模型分析坐标
3. `guiops.ps1 -Op click -X <x> -Y <y>` → 再截图验证

## 错误码

- `worker-not-running`：无新鲜心跳（>15s）。检查计划任务 `AgentDock-GuiOpsWorker` 与 `<Root>\worker.log`。
- `queue-missing`：未安装（安装方未执行 install-guiops.ps1）。
- `timeout`：worker 超时未回结果（看 worker.log）。
- `bad-op` / `bad-args` / `bad-json`：调用侧问题。
- `window-not-found`（uia）：Target 没匹配到顶层窗口（窗口未开/已托盘化/类名拼错）。

## 环境变量

| 变量 | 类型 | 必填 | 说明 |
|---|---|---:|---|
| （无） | - | - | 全部参数走命令行；Root 有默认值 |

## 约束与注意

1. **坐标为物理像素**（worker 已 SetProcessDPIAware）；建议截图后在图上量坐标。
2. 点击前后 worker 自带少量 settle 延时；连续动作间可自行插 `-Op sleep`。
3. 会话必须处于活动/已登录状态；RDP 断开会得到黑屏截图（这是 Windows 桌面渲染机制，不是本 skill 故障）。
4. 本 skill 不做任何删除、上传或网络访问；worker.log/status.json 只增不改。
5. worker 为单实例（计划任务 IgnoreNew）；重启 worker 直接 `Start-ScheduledTask`。
