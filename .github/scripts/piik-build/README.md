# Piik 补丁构建（远控稳定性）

云桌面上的 Piik 不是官方原版，而是**上游 v2.4.1 源码 + 两处本地修复**编译出来的
`piik-app.exe`。产物发布在 Release `piik-runtime-v2`，`start-piik-host.ps1` 从这里下载。

## 为什么要改

实测症状：手机端用着用着**远控权限丢了**，远端鼠标光标消失，必须重新打开邀请链接。

日志与源码定位到两条独立原因：

1. **服务端一抖动就撤权**
   `internal/app/nativehost/session.go` 与 `publication.go` 的 `ConnectionState` 回调里，
   PeerConnection 一进 `Disconnected` 就立刻 `remoteInput.RevokeEdge(connectionID)`。
   而 `Disconnected` 在 1~2% 丢包下非常常见（实测 RTT 256ms、丢包 1~2%），
   连上几秒就又回到 `Connected` —— 但授权已经被撤了，且 `remoteinput/manager.go`
   的注释明确写着「绝不恢复之前的授权」。
2. **前端授权一丢，UI 直接消失**
   `RemoteControl.tsx` 在 data channel 不是 `open` 时整块返回 `null`，
   连「请求控制」按钮都不渲染，用户只能刷新页面。

上游 v2.4.1 的 release notes 写「改善远程输入连续性」，但实际只改了鼠标事件的 4ms 节流，
**撤销授权的逻辑一字未改**，所以升级官方版解决不了。

## 改了什么

| 文件 | 改动 |
|---|---|
| `internal/app/nativehost/session.go` | `Disconnected`/`Failed` 改为延迟撤销（宽限 20s）；`Connected` 撤销待执行的延迟；仅在 `Closed` 时立即撤销。新增 `revokeTimers` 字段、`armPendingRevoke`、`cancelPendingRevoke`，`retire()` 清理定时器 |
| `internal/app/nativehost/publication.go` | 同样的三态处理（观众走转发/发布路径时也需要，否则仍会掉权） |
| `src/client/components/living/RemoteControl.tsx` | 新增 `regain` ref：真正拿到过控制权后，连接恢复且状态回到 `ready`、模式为 `room` 时**自动重新申请**，无需刷新页面；用户主动点「停止控制」则清标志，不会被强行拉回 |

`overlay/` 里放的是**改后的完整文件**，构建时直接覆盖上游同名文件。
不用 patch 是因为上游行号会漂移，整文件覆盖要么成功要么在文件缺失时明确报错。

## 怎么构建

在云桌面（或任意装有 VS 无关依赖的 Windows）上：

```powershell
pwsh -File .github/scripts/piik-build/rebuild-piik.ps1
```

脚本会：下载 Go 1.27.3（阿里云镜像）→ 下载上游源码 tar.gz → 覆盖 overlay →
`npm ci` + `npm run build:web`（vite）→ `go build -trimpath -ldflags "-s -w"`。

产出 `C:\piikbuild\out\piik-app.exe`。

注意：
- 前端是 `//go:embed all:dist` 嵌进二进制的，**改前端必须重新 go build**。
- 云桌面镜像自带 Node 22，而上游 `package.json` 声明 `engines.node >=24`。
  22 能正常构建（只有 `EBADENGINE` 警告），实测可用；若上游换成 Node 24 专有 API 再补装 Node 24。
- **`piik-capture.exe` 不用重新编译**：Release 里那份已经是打过「无 GPU」补丁的版本
  （D3D11 `VIDEO_SUPPORT` 标志已去掉、`FrameConverter` 换成 libyuv CPU 路径）。
  只替换 `piik-app.exe` 即可。

## 发布流程（当前采用）

```powershell
# 1. 替换运行中的 exe（保留备份）
Copy-Item D:\piik\piik-app.exe D:\piik\piik-app.exe.orig
Copy-Item C:\piikbuild\out\piik-app.exe D:\piik\piik-app.exe -Force

# 2. 重建房间（会换新域名，属于 Cloudflare 快速隧道特性）
pwsh -File C:\piikbuild\start-piik-host.ps1

# 3. 打包 runtime（含已打补丁的 capture）
#    robocopy D:\piik -> stage, 覆盖 piik-app.exe, 写 REVISION, tar -a -c -f
# 4. 覆盖 Release piik-runtime-v2 的 piik-runtime.zip（同名资产先删再传）
```

## 已知限制

- 宽限期固定 20 秒（`revokeGrace`）。真正断开的观众会在这 20 秒内仍占着控制权；
  想更激进可调小，但太小又挡不住抖动。
- 前端自动重取只对 `room` 模式生效（密码模式仍需人工输入密码，不能自动）。
- 卡顿本身没修：实测 RTT 256~267ms 是物理路径问题，软件改不了。
  本次只解决「抖动就掉权 / 掉了必须刷新」。
- 上游若日后再改 `RevokeEdge`（建议关注 `TNTcraftHIM/Piik` 的 release notes），
  可以丢掉本 overlay 直接跟进，届时先 diff 这三个文件确认。
