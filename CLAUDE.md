# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a PowerShell automation script for configuring SSH access to WSL2 environments on Windows systems. The script handles port forwarding, firewall configuration, and service management to enable SSH connectivity from local and external networks.

## Script Architecture

### Core Functionality Flow

1. **Validation Phase** (Lines 8-45)
   - PowerShell version check (requires 3.0+)
   - Administrator privilege verification
   - WSL installation verification
   - Mutex-based concurrent execution prevention

2. **Service Dependencies** (Lines 47-68)
   - IP Helper service (iphlpsvc) check and startup
   - Required for netsh portproxy functionality
   - Service must be running before port forwarding configuration
   - Try-catch block for robust error handling

3. **WSL State Management** (Lines 70-125)
   - WSL2 version validation with `-Force` override option
   - WSL instance startup with 15-second timeout wait
   - Background keep-alive process using `sleep 2147483647`

4. **Background Keep-Alive Process** (Lines 127-145)
   - Checks for existing WSL background process via Get-CimInstance
   - Filters for wsl.exe with "sleep 2147483647" command line
   - Starts hidden background process if not already running
   - Prevents WSL from shutting down due to inactivity

5. **IP Address Detection** (Lines 147-212)
   - Primary: eth0 interface extraction via `ip -o -4 addr show eth0`
   - Fallback: hostname -I with private IPv4 filtering
   - Excludes: loopback (127.x), APIPA (169.254.x), Docker bridge (172.17.x)
   - Validates only private IP ranges: 10.x, 172.16-31.x, 192.168.x
   - Final IPv4 validation using [System.Net.IPAddress]::Parse()

6. **SSH Service Startup** (Lines 214-254)
   - 3-second delay before service check
   - Port 22 listening verification via ss/netstat
   - Job-based startup with 10-second timeout
   - Provides sudo NOPASSWD instructions for passwordless service control
   - Continues execution even on timeout or password requirement

7. **Port Forwarding Configuration** (Lines 256-297)
   - Removes all existing rules for the target port using regex parsing
   - Iterates through all listen addresses and explicitly deletes each
   - Adds 0.0.0.0 deletion for safety
   - Creates netsh portproxy v4tov4 rule: 0.0.0.0:ListenPort → wsl_ip:22
   - Post-configuration verification with regex-escaped IP matching
   - Throws error if verification fails

8. **Firewall Rule Management** (Lines 299-311)
   - Removes existing "WSL SSH {port}" rule
   - Creates new inbound TCP rule for the listen port
   - Uses New-NetFirewallRule with explicit parameters

9. **Validation & Rollback** (Lines 313-325)
   - Test-NetConnection verification with 2-second delay
   - Warns if port doesn't immediately listen (SSH daemon may still be starting)
   - Suggests 10-20 second retry wait for delayed SSH daemon startup

10. **Success Message Output** (Lines 326-344)
   - Displays formatted success message with usage instructions
   - Shows internal network SSH connection command
   - Shows external network SSH connection command
   - Warns about Windows reboot persistence requirement
   - Provides external access setup guidance (router port forwarding, CGNAT limitations)
   - Displays current port forwarding table via netsh

11. **Error Handling & Cleanup** (Lines 346-383)
   - Catch block with automatic rollback of port proxy and firewall changes
   - Port conflict diagnostic hint
   - Finally block ensures mutex cleanup with nested try-catch for safe disposal

## Parameters

- `$ListenPort`: Port number for Windows-side SSH listener (default: 60022, range: 1-65535)
- `-Force`: Skip WSL2 version check and proceed with WSL1 (not recommended)

## Key Technical Considerations

### IP Address Resolution Strategy

The script prioritizes eth0 interface extraction to avoid Docker bridge confusion. If eth0 fails (non-standard NIC naming), it falls back to hostname -I with aggressive filtering to exclude non-private or invalid addresses.

**Multi-interface environments** (Docker, VPNs): The hostname fallback may select incorrect IPs. Script warns users about potential conflicts.

### Race Conditions and Timing

- **SSH startup**: 3-second delay before checking prevents false negatives
- **WSL startup**: 15-second timeout with 1-second polling intervals
- **Background process check**: 2-second delay after starting keep-alive
- **Port proxy verification**: 1-second delay before rule validation
- **Connectivity test**: 2-second delay before Test-NetConnection

### Port Proxy Cleanup Strategy

The script performs comprehensive cleanup of existing port proxy rules:
1. Searches for all rules matching the target port
2. Uses regex to parse listenaddress from netsh output
3. Deletes each matching rule individually by listenaddress
4. Explicitly deletes 0.0.0.0 binding as fallback
5. This prevents accumulation of stale rules with different IP addresses

### Error Recovery

The script implements transaction-like behavior:
- Tracks `$portProxyAdded` and `$firewallAdded` flags
- Rolls back changes on error via catch block
- Provides diagnostic hints for port conflicts
- Uses mutex for single-instance enforcement with proper disposal
- Finally block ensures cleanup even on exceptions

### Character Encoding

UTF-8 console encoding is explicitly set (line 21) to handle Korean comments and output correctly.

## Common Operations

### Run with Default Port (60022)
```powershell
.\WSL-SSH-Setup.ps1
```

### Run with Custom Port
```powershell
.\WSL-SSH-Setup.ps1 -ListenPort 2222
```

### Force Execution on WSL1
```powershell
.\WSL-SSH-Setup.ps1 -Force
```

### Manual Cleanup
```powershell
# Remove port forwarding
netsh interface portproxy delete v4tov4 listenport=60022 listenaddress=0.0.0.0

# Remove firewall rule
Remove-NetFirewallRule -DisplayName "WSL SSH 60022"

# Kill WSL background process (if needed)
Get-Process wsl | Where-Object { $_.CommandLine -like "*sleep 2147483647*" } | Stop-Process
```

### View Current Port Forwarding Rules
```powershell
netsh interface portproxy show v4tov4
```

### Diagnose Port Conflicts
```powershell
netsh int ipv4 show excludedportrange tcp
```

## WSL Configuration for Passwordless SSH Service

To avoid sudo password prompts during SSH service startup:

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/service ssh *, /usr/sbin/service sshd *, /bin/systemctl * ssh, /bin/systemctl * sshd" | sudo tee /etc/sudoers.d/ssh-nopasswd
sudo chmod 440 /etc/sudoers.d/ssh-nopasswd
sudo visudo -c -f /etc/sudoers.d/ssh-nopasswd
```

## External Access Setup

1. Configure router port forwarding: External {port} → Windows PC IP:{port}
2. Verify public IP at https://whatismyipaddress.com
3. Note: CGNAT/double NAT environments block external access

## Limitations and Requirements

- **Persistence**: Must re-run after Windows reboot due to WSL IP changes
- **WSL Version**: Designed for WSL2, WSL1 requires `-Force`
- **Administrator**: Must run as elevated PowerShell
- **IP Helper Service**: Must be available and startable
- **Network**: Requires private IPv4 address on WSL eth0/primary interface
- **Concurrent Execution**: Prevented via Global\WSL_SSH_Setup mutex

## Code Style Conventions

- **If-Else Formatting**: Uses `} else {` and `} catch {` style (closing brace on same line)
- **String Interpolation**: Uses `${variable}` syntax for embedded variables in strings
- **Error Handling**: Try-catch blocks with specific error actions
- **Console Output**: Emoji prefixes with ForegroundColor for visual hierarchy
