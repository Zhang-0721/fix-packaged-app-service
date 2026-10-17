# Fix-PackagedAppService

[English](README.md) | **简体中文**

修复 MSIX / 微软商店应用装不上、更新不了的问题，典型报错：

```
0x80073CF6   应用包部署失败
             具体错误：0x80070005 —— 注册 windows.service 扩展时拒绝访问
```

本工具处理的是它背后的**打包服务残留注册**，并且绕开了那个已经损坏的服务安全描述符。

Windows PowerShell 5.1 · 无依赖 · 不联网 · 无遥测

---

## 三步用法

```powershell
# 1. 只诊断，不改任何东西
.\Fix-PackagedAppService.ps1 -Diagnose

# 2. 删掉残留的服务注册（会自动提权）
.\Fix-PackagedAppService.ps1 -Fix

# 3. 重启电脑。第二阶段会在下次登录时自动跑完，把包重新注册上
```

也可以直接双击 `run-fix.cmd`，或 `run-fix.cmd -Fix`。

---

## 症状

商店应用更新，或者重装时，部署失败：

| 部署事件 | 内容 |
| --- | --- |
| 306 / 316 | `0x80070005 ... 无法注册 windows.service 扩展: 拒绝访问` |
| 331 | 回滚时 `0x8007139F ... 状态不是执行请求操作的正确状态` |
| 300 / 401 / 404 | `0x80073CF6 ... 无法注册包`，整个部署回滚 |
| 855 | `updateList: <名称>_<旧版本> is updating to <名称>_<新版本>` |

应用往往还能打开，但每次启动都会触发一次挂起的更新，更新再次失败，最终彻底打不开。
`Get-AppxPackage` 里可能显示 `Status = Servicing` / `Staged`，而

```powershell
Add-AppxPackage -Register ...
Add-AppxPackage -Path .\App.msix
```

都以同一个 `0x80070005` 失败。

## 根因

MSIX 包可以声明一个 Windows 服务：

```xml
<desktop6:Extension Category="windows.service" Executable="app\resources\agent.exe">
  <desktop6:Service Name="Vendor.Agent" StartupType="auto" StartAccount="localSystem" />
</desktop6:Extension>
```

部署时它会被落成一个真实的服务注册项：

```
HKLM\SYSTEM\CurrentControlSet\Services\Vendor.Agent
```

`Type = 0x210`（`WIN32_PACKAGED_PROCESS`），`ImagePath` 指向包目录：

```
...\WindowsApps\Vendor.App_1.2.3.0_x64__abcdefghijk\app\resources\agent.exe
```

新版本暂存后，部署流程本应把这个注册项重新指向新版本目录。**这一步一旦失败，注册项就会一直指向一个已经不存在（或正在被删除）的版本目录**，此后所有注册尝试都卡在同一个服务扩展上。

有两个原因让它没法用常规手段抢救：

1. **服务对象的安全描述符里没有 `BUILTIN\Administrators`，也没有 `NT AUTHORITY\SYSTEM`。** 典型形态：

   ```
   D:(A;;CCLCSWRPWPDTLOCRRC;;;AU)
     (A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;S-1-5-80-1949724575-2387902436-65106593-1201171665-3967308604)
   ```

   只有 `Authenticated Users`（查询、启停等权限）和一个服务 SID（完全控制）。这是打包服务的**正常**形态——同一台机器上微软自家的无关服务也有逐字节相同的描述符，并不是哪个厂商弄坏了。但后果很硬：除此之外的任何人，包括提权后的管理员，用 SCM 都碰不了这个对象。

   ```
   > sc.exe delete Vendor.Agent
   [SC] OpenService 失败 5:
   拒绝访问。
   ```

   `sc.exe sdset`、`Set-Service`、以及往 `...\Services\<名称>\Security` 写 DACL 全都无效（那里不持久化安全描述符）。

2. **但服务的注册表键是好的。** 该键的所有者是 `BUILTIN\Administrators`，并给了完全控制。因此可以**直接从注册表删掉这个注册项**，剩下的只是让 SCM 把内存里的缓存丢掉——重启即可。

这个不对称，就是本工具的全部原理。

## 工作流程

### 第一阶段（`-Fix`）

1. 枚举 `HKLM\SYSTEM\CurrentControlSet\Services` 下 `Type = 0x210` 的服务。
2. 挑出 `ImagePath` **指向的文件已不存在**的那些（可用 `-PackageFamilyName` / `-ServiceName` 进一步限定）。
3. `Stop-Service`，然后删除注册表键（`Remove-Item -Recurse`，兜底 `reg.exe delete /f`）。
4. 把受影响的包家族写进 `%ProgramData%\PackagedServiceRepair\state.json`。
5. 注册一次性计划任务：下次登录时以最高权限执行第二阶段。
6. 提示重启。

重启不是可选项：服务管理器在内存里缓存服务记录，重启之前重新注册仍然会失败。

### 第二阶段（`-Phase2`，登录后自动执行）

1. 等桌面与状态库稳定下来。
2. 依次尝试重新注册：
   - `Add-AppxPackage -Register <最新已暂存的 AppxManifest.xml>`
   - 同上加 `-DisableDevelopmentMode`
   - `Add-AppxPackage -RegisterByFamilyName -MainPackage <包家族名>`
   - 传了 `-MsixPath` 的话，改为 `Add-AppxPackage -Path <你的 .msix>`
3. 校验服务注册现在能指向真实文件，并启动服务。
4. 向应用发一次启动请求。
5. 打印最近的部署错误，并删除计划任务。

## 如何验证

```powershell
# 注册项指向的文件又存在了
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Vendor.Agent' | Select-Object ImagePath, Start
Test-Path ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Vendor.Agent').ImagePath.Trim('"'))

# 部署成功了
Get-WinEvent -FilterHashtable @{
  LogName   = 'Microsoft-Windows-AppXDeploymentServer/Operational'
  StartTime = (Get-Date).AddHours(-1)
} | Where-Object Id -in 400,404 | Format-Table TimeCreated, Id, Message -Wrap
```

成功标志是事件 **400**（`操作已成功完成`），且之后没有 404 / 300。

跨版本更新后第一次启动可能很慢——几十秒到几分钟，因为渲染缓存要重建、新二进制要过一次杀毒扫描。很容易被误判成"卡死"。

## 安全性

- `-Diagnose` 严格只读。
- `-Fix` 只删那些可执行文件路径已经不存在的服务注册；还能解析到的注册项不动，除非你用 `-ServiceName` 点名。
- 可以用 `-PackageFamilyName` 进一步缩范围。
- 本工具**不联网、不带遥测、不读取任何凭据**。
- 建议先读源码再用。它只有几百行朴素 PowerShell。

## 已知限制

- **这不是永久修复。** 每次更新都要重新对齐服务注册项，同样的问题可能再来一次；再跑一遍本工具即可（它是幂等的）。
- **`0x80073D26` 变体**（"无法注册 windows.service 扩展，因为已安装了不同版本的服务"）：这种情况下失效的注册项可能仍指向一个存在的文件，自动检测会跳过它，需要点名：

  ```powershell
  .\Fix-PackagedAppService.ps1 -Fix -ServiceName 'Vendor.Agent'
  ```

- **从未成功安装过的包**：第二阶段没有可暂存的版本可注册，请直接给包文件：

  ```powershell
  .\Fix-PackagedAppService.ps1 -Fix -MsixPath .\App-x64.msix -Reboot
  ```

- 某些加固环境会连注册表删除也拒绝，此时工具会如实报错，而不是假装成功。

## 排错对照表

| 现象 | 含义 |
| --- | --- |
| `-Diagnose` 什么都没列出来 | 包里没有 `windows.service` 扩展，或者当前版本注册是干净的。看它打印的部署日志。 |
| 第一阶段删除时"拒绝访问" | 注册表键对你只读。请用真正提权的进程跑（不只是管理员账户）。 |
| 第二阶段仍报 `0x80070005` | 服务缓存没清掉：没重启，或旧进程又起来了。重启后手动跑一次 `-Phase2`。 |
| 第二阶段报 `0x80073CF6`，卡在别的扩展上 | 是另一个清单扩展在失败，日志里会写明；`windows.fileTypeAssociation` 是已知的同类问题。 |
| 一切成功但应用打开很慢 | 跨版本更新后的首次启动正常现象。耐心等，不要杀进程。 |

## 相关上游报告

同一个缺陷，不同厂商——都是打包服务：

- `openai/codex` #53132、#45511、#25770
- `anthropics/claude-code` #57035、#78873、#76357、#92141
- `microsoft/msix-packaging` #558

请注意：那些 issue 里流传的 `icacls` 方案修的是**包目录**的 ACL，而失败点不在这里——注册是在**服务对象的安全描述符**上失败的，所以那些方案会报"修复成功"却毫无效果。

## 兼容性

- Windows 10 1809+ / Windows 11
- Windows PowerShell 5.1（系统自带的那个），不需要 PowerShell 7
- 脚本刻意写成纯 ASCII：Windows PowerShell 5.1 会用系统 ANSI 代码页解码没有 BOM 的 `.ps1`，非 ASCII 文本会导致在非英文系统上出现莫名其妙的 `缺少右"}"` 解析错误。

## 许可

MIT。与 Microsoft、OpenAI、Anthropic 均无关联。
