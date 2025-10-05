# WSL SSH Auto Setup

PowerShell script to automatically configure WSL2 SSH port forwarding on Windows boot

## Overview

WSL2 changes its IP address on every reboot, breaking SSH connectivity. This script:
- Automatically detects WSL IP on Windows boot
- Creates port forwarding rules (default: 60022 → WSL:22)
- Configures firewall automatically
- Keeps WSL running in the background

## Key Features

- **Automatic IP Detection**: Extracts accurate WSL IP from eth0 interface (excludes Docker bridge)
- **Security**: Automatic IP Helper service check, only allows private IPs
- **Auto SSH Start**: 3-second wait before status check, starts only when needed
- **Complete Rollback**: Automatically removes added configurations on failure
- **Internal/External Network Support**: Works for both local network and internet access
- **Stability**: Prevents concurrent execution with mutex, handles all errors

## Requirements

- Windows 10/11 (PowerShell 3.0 or higher)
- WSL2 installed and configured
- SSH server installed inside WSL (`openssh-server`)
- Administrator privileges

## Installation

### 1. Download Script

```powershell
# Create script folder
New-Item -Path "C:\Scripts" -ItemType Directory -Force

# Download script from this repository
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/GSK-KR/wsl-ssh-setup/main/WSL-SSH-Setup.ps1" -OutFile "C:\Scripts\WSL-SSH-Setup.ps1"
```

Or download manually:
1. Download `WSL-SSH-Setup.ps1`
2. Save to `C:\Scripts\` folder

### 2. Install SSH Server in WSL (if not installed)

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install openssh-server -y

# Start SSH service
sudo service ssh start

# Enable auto-start on boot (optional)
sudo systemctl enable ssh
```

### 3. Configure Passwordless sudo for SSH (Recommended)

Run inside WSL:

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/service ssh *, /usr/sbin/service sshd *, /bin/systemctl * ssh, /bin/systemctl * sshd" | sudo tee /etc/sudoers.d/ssh-nopasswd
sudo chmod 440 /etc/sudoers.d/ssh-nopasswd
sudo visudo -c -f /etc/sudoers.d/ssh-nopasswd
```

## Usage

### Manual Execution

```powershell
# Run PowerShell as Administrator, then:
C:\Scripts\WSL-SSH-Setup.ps1

# Use different port
C:\Scripts\WSL-SSH-Setup.ps1 -ListenPort 2222

# Force execution on WSL1
C:\Scripts\WSL-SSH-Setup.ps1 -Force
```

### Auto-register with Task Scheduler

**Method 1: PowerShell Auto-registration (Recommended)**

Create `RegisterScheduledTask.ps1` file with the following content:

```powershell
# Check administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ Please run as Administrator"
    exit 1
}

# Script path
$scriptPath = "C:\Scripts\WSL-SSH-Setup.ps1"

# Check script file exists
if (-not (Test-Path $scriptPath)) {
    Write-Error "❌ Script not found: $scriptPath"
    exit 1
}

# Remove existing task
Unregister-ScheduledTask -TaskName "WSL SSH Setup" -ErrorAction SilentlyContinue -Confirm:$false

# Define task action
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

# Define trigger (at startup)
$trigger = New-ScheduledTaskTrigger -AtStartup

# Define settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# Define principal (SYSTEM account)
$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# Register task
Register-ScheduledTask `
    -TaskName "WSL SSH Setup" `
    -Description "Auto-configure WSL SSH port forwarding at boot" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force

Write-Host "✅ Task Scheduler registration complete!" -ForegroundColor Green
```

**Run as Administrator:**

```powershell
.\RegisterScheduledTask.ps1
```

**Method 2: Manual GUI Registration**

1. Press `Win + R` → Enter `taskschd.msc`
2. Click **"Create Basic Task"**
3. Name: `WSL SSH Setup`, Description: `Auto-configure WSL SSH port forwarding at boot`
4. Trigger: Select **"When the computer starts"**
5. Action: Select **"Start a program"**
   - Program: `powershell.exe`
   - Arguments: `-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Scripts\WSL-SSH-Setup.ps1"`
6. After finishing, double-click the task for additional settings:
   - **General tab**: Check "Run with highest privileges", change user to `SYSTEM`
   - **Triggers tab**: Set "Delay task for" → 30 seconds
   - **Configure for**: Select `Windows 10`
   - **Settings tab**:
     - "If the task fails, restart every: 1 minute, 3 times"
     - "Start the task only if the computer is on battery power"

## Testing

### Test Immediate Execution

```powershell
Start-ScheduledTask -TaskName "WSL SSH Setup"
```

### Verify Configuration

```powershell
# Check port forwarding
netsh interface portproxy show v4tov4

# Check firewall rules
Get-NetFirewallRule -DisplayName "WSL SSH*"

# Check task status
Get-ScheduledTask -TaskName "WSL SSH Setup" | Get-ScheduledTaskInfo
```

### Test SSH Connection

```bash
# From internal network
ssh username@LocalIP:60022

# From external network (requires router port forwarding)
ssh username@PublicIP:60022
```

## External Access Setup

### 1. Router Port Forwarding

- External Port: `60022`
- Internal IP: Local IP of Windows PC
- Internal Port: `60022`

### 2. Check Public IP

```powershell
(Invoke-WebRequest -Uri "https://api.ipify.org").Content
```

Or visit https://whatismyipaddress.com

### 3. Check for CGNAT

If router's external IP differs from actual public IP, you're behind CGNAT → external access impossible

## Troubleshooting

### Task Scheduler Not Running

```powershell
# Check last run result
Get-ScheduledTask -TaskName "WSL SSH Setup" | Select-Object TaskName, State, LastRunTime, LastTaskResult

# Check event log
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 20 |
    Where-Object { $_.Message -like "*WSL SSH Setup*" } |
    Format-List TimeCreated, Message
```

### SSH Connection Failed

```powershell
# Check WSL IP
wsl hostname -I

# Check port listening
Test-NetConnection -ComputerName localhost -Port 60022

# Check SSH status inside WSL
wsl -e sh -c "service ssh status"
```

### Port Conflict

```powershell
# Check reserved port ranges
netsh int ipv4 show excludedportrange tcp
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-ListenPort` | Port number to listen on Windows (1-65535) | `60022` |
| `-Force` | Force execution even on WSL1 | None |

**Usage examples:**

```powershell
# Use port 2222
.\WSL-SSH-Setup.ps1 -ListenPort 2222

# Force execution on WSL1
.\WSL-SSH-Setup.ps1 -Force
```

## Important Notes

- WSL IP changes on every Windows reboot, so **auto-run on boot setup is mandatory**
- For external access, **SSH key authentication** is strongly recommended (password auth is risky)
- External access impossible in CGNAT/double NAT environments
- Firewall rules are meaningless if Windows Firewall is disabled

## License

MIT License

## Contributing

Issues and PRs are always welcome!

## Support

If you encounter problems, please create an issue.

---

Made with ❤️ for WSL users
