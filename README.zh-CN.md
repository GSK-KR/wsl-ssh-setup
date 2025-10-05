# WSL SSH 自动设置

Windows 启动时自动配置 WSL2 SSH 端口转发的 PowerShell 脚本

## 概述

WSL2 每次重启时 IP 地址都会改变，导致 SSH 连接失败。此脚本可以：
- 在 Windows 启动时自动检测 WSL IP
- 自动创建端口转发规则（默认：60022 → WSL:22）
- 自动配置防火墙
- 保持 WSL 在后台运行

## 主要功能

- **自动 IP 检测**：从 eth0 接口提取准确的 WSL IP（排除 Docker 网桥）
- **安全性**：自动检查 IP Helper 服务，仅允许私有 IP
- **自动启动 SSH**：等待 3 秒后检查状态，仅在需要时启动
- **完整回滚**：失败时自动删除已添加的配置
- **内外网支持**：支持局域网和互联网访问
- **稳定性**：使用互斥锁防止并发执行，处理所有错误

## 系统要求

- Windows 10/11（PowerShell 3.0 或更高版本）
- 已安装和配置 WSL2
- WSL 内部已安装 SSH 服务器（`openssh-server`）
- 管理员权限

## 安装

### 1. 下载脚本

```powershell
# 创建脚本文件夹
New-Item -Path "C:\Scripts" -ItemType Directory -Force

# 从此仓库下载脚本
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/GSK-KR/wsl-ssh-setup/main/WSL-SSH-Setup.ps1" -OutFile "C:\Scripts\WSL-SSH-Setup.ps1"
```

或手动下载：
1. 下载 `WSL-SSH-Setup.ps1`
2. 保存到 `C:\Scripts\` 文件夹

### 2. 在 WSL 中安装 SSH 服务器（如果未安装）

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install openssh-server -y

# 启动 SSH 服务
sudo service ssh start

# 开机自动启动（可选）
sudo systemctl enable ssh
```

### 3. 配置无密码 sudo 启动 SSH（推荐）

在 WSL 内运行：

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/service ssh *, /usr/sbin/service sshd *, /bin/systemctl * ssh, /bin/systemctl * sshd" | sudo tee /etc/sudoers.d/ssh-nopasswd
sudo chmod 440 /etc/sudoers.d/ssh-nopasswd
sudo visudo -c -f /etc/sudoers.d/ssh-nopasswd
```

## 使用方法

### 手动执行

```powershell
# 以管理员身份运行 PowerShell，然后：
C:\Scripts\WSL-SSH-Setup.ps1

# 使用其他端口
C:\Scripts\WSL-SSH-Setup.ps1 -ListenPort 2222

# 在 WSL1 上强制执行
C:\Scripts\WSL-SSH-Setup.ps1 -Force
```

### 使用任务计划程序自动注册

**方法 1：PowerShell 自动注册（推荐）**

创建 `RegisterScheduledTask.ps1` 文件，包含以下内容：

```powershell
# 检查管理员权限
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ 请以管理员身份运行"
    exit 1
}

# 脚本路径
$scriptPath = "C:\Scripts\WSL-SSH-Setup.ps1"

# 检查脚本文件是否存在
if (-not (Test-Path $scriptPath)) {
    Write-Error "❌ 找不到脚本：$scriptPath"
    exit 1
}

# 删除现有任务
Unregister-ScheduledTask -TaskName "WSL SSH Setup" -ErrorAction SilentlyContinue -Confirm:$false

# 定义任务操作
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

# 定义触发器（启动时）
$trigger = New-ScheduledTaskTrigger -AtStartup

# 定义设置
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# 定义主体（SYSTEM 账户）
$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# 注册任务
Register-ScheduledTask `
    -TaskName "WSL SSH Setup" `
    -Description "启动时自动配置 WSL SSH 端口转发" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force

Write-Host "✅ 任务计划程序注册完成！" -ForegroundColor Green
```

**以管理员身份运行：**

```powershell
.\RegisterScheduledTask.ps1
```

**方法 2：GUI 手动注册**

1. 按 `Win + R` → 输入 `taskschd.msc`
2. 点击 **"创建基本任务"**
3. 名称：`WSL SSH Setup`，说明：`启动时自动配置 WSL SSH 端口转发`
4. 触发器：选择 **"计算机启动时"**
5. 操作：选择 **"启动程序"**
   - 程序：`powershell.exe`
   - 参数：`-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Scripts\WSL-SSH-Setup.ps1"`
6. 完成后，双击任务进行其他设置：
   - **常规选项卡**：勾选"使用最高权限运行"，将用户更改为 `SYSTEM`
   - **触发器选项卡**：设置"延迟任务时间" → 30 秒
   - **配置**：选择 `Windows 10`
   - **设置选项卡**：
     - "如果任务失败，重启间隔：1 分钟，3 次"
     - "即使使用电池供电，也启动任务"

## 测试

### 测试立即执行

```powershell
Start-ScheduledTask -TaskName "WSL SSH Setup"
```

### 验证配置

```powershell
# 检查端口转发
netsh interface portproxy show v4tov4

# 检查防火墙规则
Get-NetFirewallRule -DisplayName "WSL SSH*"

# 检查任务状态
Get-ScheduledTask -TaskName "WSL SSH Setup" | Get-ScheduledTaskInfo
```

### 测试 SSH 连接

```bash
# 从内部网络
ssh username@本地IP:60022

# 从外部网络（需要路由器端口转发）
ssh username@公网IP:60022
```

## 外部访问设置

### 1. 路由器端口转发

- 外部端口：`60022`
- 内部 IP：Windows PC 的本地 IP
- 内部端口：`60022`

### 2. 查看公网 IP

```powershell
(Invoke-WebRequest -Uri "https://api.ipify.org").Content
```

或访问 https://whatismyipaddress.com

### 3. 检查 CGNAT

如果路由器的外部 IP 与实际公网 IP 不同，则表示在 CGNAT 环境中 → 无法进行外部访问

## 故障排除

### 任务计划程序未运行

```powershell
# 检查上次运行结果
Get-ScheduledTask -TaskName "WSL SSH Setup" | Select-Object TaskName, State, LastRunTime, LastTaskResult

# 检查事件日志
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 20 |
    Where-Object { $_.Message -like "*WSL SSH Setup*" } |
    Format-List TimeCreated, Message
```

### SSH 连接失败

```powershell
# 检查 WSL IP
wsl hostname -I

# 检查端口监听
Test-NetConnection -ComputerName localhost -Port 60022

# 检查 WSL 内部 SSH 状态
wsl -e sh -c "service ssh status"
```

### 端口冲突

```powershell
# 检查保留端口范围
netsh int ipv4 show excludedportrange tcp
```

## 参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-ListenPort` | Windows 监听端口号（1-65535） | `60022` |
| `-Force` | 即使在 WSL1 上也强制执行 | 无 |

**使用示例：**

```powershell
# 使用 2222 端口
.\WSL-SSH-Setup.ps1 -ListenPort 2222

# 在 WSL1 上强制执行
.\WSL-SSH-Setup.ps1 -Force
```

## 注意事项

- 每次 Windows 重启时 WSL IP 都会改变，因此**必须设置启动时自动运行**
- 对于外部访问，**强烈建议使用 SSH 密钥认证**（密码认证有风险）
- 在 CGNAT/双重 NAT 环境中无法进行外部访问
- 如果 Windows 防火墙已禁用，防火墙规则将无意义

## 许可证

MIT License

## 贡献

欢迎随时提交 Issue 和 PR！

## 支持

如果遇到问题，请创建 Issue。

---

Made with ❤️ for WSL users
