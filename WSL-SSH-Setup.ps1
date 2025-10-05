# Script parameters
param(
    [switch]$Force,
    [ValidateRange(1, 65535)]
    [int]$ListenPort = 60022
)

# PowerShell version check
if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Error "PowerShell 3.0 or higher is required"
    exit 1
}

# Check administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "Please run with administrator privileges"
    exit 1
}

# UTF-8 encoding settings
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Variable initialization
$mutex = $null
$mutexAcquired = $false
$portProxyAdded = $false
$firewallAdded = $false

try {
    # Create mutex
    $mutex = New-Object System.Threading.Mutex($false, "Global\WSL_SSH_Setup")

    # Prevent concurrent execution
    if (-not $mutex.WaitOne(0)) {
        Write-Error "Another instance is already running"
        exit 1
    }
    $mutexAcquired = $true

    # Check WSL installation
    $wslCheck = Get-Command wsl -ErrorAction SilentlyContinue
    if (-not $wslCheck) {
        Write-Error "WSL is not installed"
        exit 1
    }

    # Check IP Helper service (portproxy dependency)
    Write-Host "Checking IP Helper service..." -ForegroundColor Cyan
    $ipHelper = Get-Service -Name iphlpsvc -ErrorAction SilentlyContinue

    if (-not $ipHelper) {
        Write-Error "IP Helper service not found"
        exit 1
    }

    if ($ipHelper.Status -ne 'Running') {
        Write-Host "Starting IP Helper service..." -ForegroundColor Yellow
        try {
            Start-Service -Name iphlpsvc -ErrorAction Stop
            Write-Host "IP Helper service started successfully" -ForegroundColor Green
        } catch {
            Write-Error "Failed to start IP Helper service: $_"
            Write-Host "portproxy requires IP Helper service" -ForegroundColor Yellow
            exit 1
        }
    } else {
        Write-Host "IP Helper service is running" -ForegroundColor Green
    }

    # Check WSL version and status
    Write-Host "Checking WSL version..." -ForegroundColor Cyan
    $wslInfo = wsl -l -v 2>&1

    # Find default distribution
    $defaultDistro = ($wslInfo -split "`r?`n" | Where-Object { $_ -match "\*" } | Select-Object -First 1)

    if (-not $defaultDistro) {
        Write-Error "Default WSL distribution not found"
        exit 1
    }

    $defaultDistro = $defaultDistro.Trim()

    # Check WSL2
    $isWSL2 = $defaultDistro -match "2\s*$" -or $defaultDistro -match "Version\s*2"

    if (-not $isWSL2) {
        if ($Force) {
            Write-Warning "Not WSL2 but continuing with -Force parameter"
        } else {
            Write-Error "Default distribution is not WSL2. Can force execution with -Force parameter"
            Write-Host "Current: $defaultDistro" -ForegroundColor Yellow
            exit 1
        }
    }

    # Check WSL running status
    Write-Host "Checking WSL status..." -ForegroundColor Cyan
    $wslRunning = $defaultDistro -match "(Running|실행 중)"

    if (-not $wslRunning) {
        Write-Host "Starting WSL..." -ForegroundColor Yellow
        wsl -e true 2>&1 | Out-Null

        # Wait for WSL to start
        $wslStarted = $false
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            $checkStatus = wsl -l -v 2>&1
            $defaultCheck = ($checkStatus -split "`r?`n" | Where-Object { $_ -match "\*" } | Select-Object -First 1)

            if ($defaultCheck -and $defaultCheck -match "(Running|실행 중)") {
                Write-Host "WSL started successfully" -ForegroundColor Green
                $wslStarted = $true
                break
            }
        }

        if (-not $wslStarted) {
            Write-Error "WSL startup failed (15 second timeout)"
            exit 1
        }
    } else {
        Write-Host "WSL already running" -ForegroundColor Green
    }

    # Check WSL background keep-alive process
    Write-Host "Checking WSL background keep-alive..." -ForegroundColor Yellow

    try {
        $keepAliveProcess = Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe'" -ErrorAction Stop | Where-Object {
            $_.CommandLine -ne $null -and $_.CommandLine -like "*sleep 2147483647*"
        }
    } catch {
        Write-Warning "Process check failed: $_"
        $keepAliveProcess = $null
    }

    if (-not $keepAliveProcess) {
        Start-Process -WindowStyle Hidden -FilePath "wsl.exe" -ArgumentList "-e", "sh", "-c", "sleep 2147483647"
        Start-Sleep -Seconds 2
        Write-Host "WSL background keep-alive enabled" -ForegroundColor Green
    } else {
        Write-Host "WSL background keep-alive already active" -ForegroundColor Green
    }

    # Get WSL IP (extract only IPv4 from eth0)
    Write-Host "Checking WSL IP..." -ForegroundColor Yellow

    # Get IP from eth0 only (exclude Docker bridge, etc.)
    $wsl_ip_raw = wsl -e sh -c "ip -o -4 addr show eth0 2>/dev/null | awk '{print \`$4}' | cut -d/ -f1" 2>&1

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($wsl_ip_raw)) {
        # Fallback to hostname -I if eth0 fails
        Write-Warning "Cannot get eth0 IP (may be non-standard NIC name). Trying hostname -I..."
        $wsl_ip_raw = wsl hostname -I 2>&1

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($wsl_ip_raw)) {
            Write-Error "Cannot get WSL IP"
            exit 1
        }

        # Filter private IPv4 only
        $ipv4Addresses = ($wsl_ip_raw.Trim() -split '\s+') | Where-Object {
            try {
                $ip = [System.Net.IPAddress]::Parse($_)
                if ($ip.AddressFamily -ne 'InterNetwork') { return $false }

                $bytes = $ip.GetAddressBytes()

                # Exclude loopback
                if ($bytes[0] -eq 127) { return $false }

                # Exclude APIPA
                if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }

                # Exclude Docker bridge (172.17.0.0/16)
                if ($bytes[0] -eq 172 -and $bytes[1] -eq 17) { return $false }

                # Private IP only
                ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
                ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
                ($bytes[0] -eq 10)
            } catch {
                $false
            }
        }

        if (-not $ipv4Addresses -or $ipv4Addresses.Count -eq 0) {
            Write-Error "No valid private IPv4 address found"
            Write-Host "Received IP: $wsl_ip_raw" -ForegroundColor Yellow
            exit 1
        }

        $wsl_ip = $ipv4Addresses[0]
        Write-Warning "IP may be incorrect if Docker or other interfaces exist"
    } else {
        $wsl_ip = $wsl_ip_raw.Trim()
    }

    # Final IP validation
    try {
        $parsedIP = [System.Net.IPAddress]::Parse($wsl_ip)
        if ($parsedIP.AddressFamily -ne 'InterNetwork') {
            throw "Not IPv4"
        }
    } catch {
        Write-Error "Invalid IP address: $wsl_ip"
        exit 1
    }

    Write-Host "WSL IP: $wsl_ip" -ForegroundColor Cyan

    # Check SSH service status (after 3 second wait)
    Write-Host "Checking SSH service (waiting 3 seconds)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3

    # Check port 22 listening
    $sshCheck = wsl -e sh -c "(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -q ':22 ' && echo 'running' || echo 'stopped'"

    if ($sshCheck -match "running") {
        Write-Host "SSH service already running" -ForegroundColor Green
    } else {
        Write-Host "Starting SSH service..." -ForegroundColor Yellow

        $job = Start-Job -ScriptBlock {
            wsl -e sh -c "sudo systemctl start ssh 2>/dev/null || sudo systemctl start sshd 2>/dev/null || sudo service ssh start 2>/dev/null || sudo service sshd start 2>&1"
        }

        $completed = Wait-Job $job -Timeout 10

        if ($completed) {
            $result = Receive-Job $job
            Remove-Job $job

            if ($result -match "(?i)password") {
                Write-Warning "Sudo password required to start SSH service"
                Write-Host ""
                Write-Host "To start SSH without sudo password, run in WSL:" -ForegroundColor Yellow
                Write-Host '   echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/service ssh *, /usr/sbin/service sshd *, /bin/systemctl * ssh, /bin/systemctl * sshd" | sudo tee /etc/sudoers.d/ssh-nopasswd' -ForegroundColor White
                Write-Host "   sudo chmod 440 /etc/sudoers.d/ssh-nopasswd" -ForegroundColor White
                Write-Host "   sudo visudo -c -f /etc/sudoers.d/ssh-nopasswd" -ForegroundColor White
                Write-Host ""
                Write-Host "Continuing..." -ForegroundColor Yellow
            } else {
                Write-Host "SSH service started successfully" -ForegroundColor Green
            }
        } else {
            Stop-Job $job
            Remove-Job $job
            Write-Warning "SSH service startup timeout"
            Write-Host "Continuing..." -ForegroundColor Yellow
        }
    }

    # Remove all existing port proxy rules (all listenaddress entries)
    Write-Host "Removing existing port proxy rules..." -ForegroundColor Yellow

    # Find all rules for this port
    $existingRules = netsh interface portproxy show v4tov4 | Select-String $ListenPort

    if ($existingRules) {
        # Parse and extract all listenaddress values for deletion
        $proxyOutput = netsh interface portproxy show v4tov4
        $lines = $proxyOutput -split "`r?`n"

        foreach ($line in $lines) {
            if ($line -match $ListenPort) {
                # Handle various output formats
                if ($line -match "(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+$ListenPort") {
                    $listenAddr = $matches[1]
                    Write-Host "   Deleting existing rule: ${listenAddr}:${ListenPort}" -ForegroundColor Gray
                    netsh interface portproxy delete v4tov4 listenport=$ListenPort listenaddress=$listenAddr 2>&1 | Out-Null
                }
            }
        }

        # Also explicitly delete 0.0.0.0
        netsh interface portproxy delete v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 2>&1 | Out-Null
    }

    # Add new port proxy rule
    Write-Host "Configuring port forwarding (${ListenPort} -> ${wsl_ip}:22)..." -ForegroundColor Yellow
    netsh interface portproxy add v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 connectport=22 connectaddress=$wsl_ip 2>&1 | Out-Null
    $portProxyAdded = $true

    # Verify
    Start-Sleep -Seconds 1
    $escapedIP = [regex]::Escape($wsl_ip)
    $proxyOutput = netsh interface portproxy show v4tov4
    $verifyProxy = $proxyOutput | Select-String $ListenPort | Select-String $escapedIP

    if (-not $verifyProxy) {
        throw "Port proxy verification failed - rule was not added correctly"
    }

    Write-Host "Port forwarding configuration complete" -ForegroundColor Green

    # Configure firewall rules
    Write-Host "Configuring firewall rules..." -ForegroundColor Yellow
    Remove-NetFirewallRule -DisplayName "WSL SSH $ListenPort" -ErrorAction SilentlyContinue

    New-NetFirewallRule -DisplayName "WSL SSH $ListenPort" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $ListenPort `
        -ErrorAction Stop | Out-Null

    $firewallAdded = $true
    Write-Host "Firewall rule added successfully" -ForegroundColor Green

    # Connectivity test
    Write-Host "Testing connectivity..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2

    $testResult = Test-NetConnection -ComputerName localhost -Port $ListenPort -WarningAction SilentlyContinue -InformationLevel Quiet

    if ($testResult) {
        Write-Host "Port $ListenPort listening confirmed" -ForegroundColor Green
    } else {
        Write-Warning "Port $ListenPort is not immediately listening"
        Write-Host "   SSH daemon may still be starting (retry recommended after 10-20 seconds)" -ForegroundColor Yellow
    }

    # Success message
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    Write-Host "All configuration complete!" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Internal network SSH connection: ssh username@localIP:${ListenPort}" -ForegroundColor Cyan
    Write-Host "External network SSH connection: ssh username@publicIP:${ListenPort}" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Important notes:" -ForegroundColor Yellow
    Write-Host "   - Re-run this script after Windows reboot (WSL IP changes)" -ForegroundColor White
    Write-Host ""
    Write-Host "Additional setup for external access:" -ForegroundColor Yellow
    Write-Host "   1. Configure router port forwarding: External ${ListenPort} -> This PC IP:${ListenPort}" -ForegroundColor White
    Write-Host "   2. External access may not work in CGNAT/double NAT environments" -ForegroundColor White
    Write-Host "   3. Check public IP: https://whatismyipaddress.com" -ForegroundColor White
    Write-Host ""
    Write-Host "Current port forwarding:" -ForegroundColor Cyan
    netsh interface portproxy show v4tov4

} catch {
    Write-Error "Error occurred: $_"
    Write-Host ""

    # Port conflict hint
    if ($_ -match "port") {
        Write-Host "Port conflict diagnostic: netsh int ipv4 show excludedportrange tcp" -ForegroundColor Yellow
    }

    # Attempt rollback
    if ($portProxyAdded) {
        Write-Host "Rolling back port proxy..." -ForegroundColor Yellow
        netsh interface portproxy delete v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 2>&1 | Out-Null
    }

    if ($firewallAdded) {
        Write-Host "Rolling back firewall rule..." -ForegroundColor Yellow
        Remove-NetFirewallRule -DisplayName "WSL SSH $ListenPort" -ErrorAction SilentlyContinue
    }

    exit 1
} finally {
    # Safely release mutex
    if ($mutexAcquired -and $mutex) {
        try {
            $mutex.ReleaseMutex()
        } catch {
            # Ignore
        }
    }
    if ($mutex) {
        try {
            $mutex.Dispose()
        } catch {
            # Ignore
        }
    }
}
