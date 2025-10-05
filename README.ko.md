# WSL SSH Auto Setup

Windows 부팅 시 WSL2 SSH 포트 포워딩을 자동으로 설정하는 PowerShell 스크립트

## 개요

WSL2는 재부팅할 때마다 IP 주소가 변경되어 SSH 접속이 불가능해집니다. 이 스크립트는:
- Windows 부팅 시 자동으로 WSL IP를 감지
- 포트 포워딩 규칙 자동 생성 (기본: 60022 → WSL:22)
- 방화벽 자동 설정
- WSL 백그라운드 자동 실행 유지

## 주요 기능

- **자동 IP 감지**: eth0 인터페이스에서 정확한 WSL IP 추출 (Docker 브리지 제외)
- **보안**: IP Helper 서비스 자동 체크, 프라이빗 IP만 허용
- **SSH 자동 시작**: 3초 대기 후 상태 확인, 필요 시에만 시작
- **완벽한 롤백**: 실패 시 추가된 설정 자동 제거
- **내부/외부망 지원**: 로컬 네트워크 및 인터넷 접속 모두 가능
- **안정성**: 뮤텍스로 동시 실행 방지, 모든 에러 처리

## 요구사항

- Windows 10/11 (PowerShell 3.0 이상)
- WSL2 설치 및 설정 완료
- SSH 서버가 WSL 내부에 설치됨 (`openssh-server`)
- 관리자 권한

## 설치 방법

### 1. 스크립트 다운로드

```powershell
# 스크립트 저장 폴더 생성
New-Item -Path "C:\Scripts" -ItemType Directory -Force

# 이 저장소에서 스크립트 다운로드
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/GSK-KR/wsl-ssh-setup/main/WSL-SSH-Setup.ps1" -OutFile "C:\Scripts\WSL-SSH-Setup.ps1"
```

또는 직접 다운로드:
1. `WSL-SSH-Setup.ps1` 다운로드
2. `C:\Scripts\` 폴더에 저장

### 2. WSL에서 SSH 서버 설치 (미설치 시)

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install openssh-server -y

# SSH 서비스 시작
sudo service ssh start

# 부팅 시 자동 시작 (선택사항)
sudo systemctl enable ssh
```

### 3. sudo 비밀번호 없이 SSH 시작 (권장)

WSL 내부에서 실행:

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/service ssh *, /usr/sbin/service sshd *, /bin/systemctl * ssh, /bin/systemctl * sshd" | sudo tee /etc/sudoers.d/ssh-nopasswd
sudo chmod 440 /etc/sudoers.d/ssh-nopasswd
sudo visudo -c -f /etc/sudoers.d/ssh-nopasswd
```

## 사용 방법

### 수동 실행

```powershell
# 관리자 권한으로 PowerShell 실행 후
C:\Scripts\WSL-SSH-Setup.ps1

# 다른 포트 사용 시
C:\Scripts\WSL-SSH-Setup.ps1 -ListenPort 2222

# WSL1에서 강제 실행 시
C:\Scripts\WSL-SSH-Setup.ps1 -Force
```

### 작업 스케줄러 자동 등록

**방법 1: PowerShell 자동 등록 (권장)**

`RegisterScheduledTask.ps1` 파일을 생성하고 아래 내용 입력:

```powershell
# 관리자 권한 확인
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ 관리자 권한으로 실행해주세요"
    exit 1
}

# 스크립트 경로
$scriptPath = "C:\Scripts\WSL-SSH-Setup.ps1"

# 스크립트 파일 존재 확인
if (-not (Test-Path $scriptPath)) {
    Write-Error "❌ 스크립트를 찾을 수 없습니다: $scriptPath"
    exit 1
}

# 기존 작업 제거
Unregister-ScheduledTask -TaskName "WSL SSH Setup" -ErrorAction SilentlyContinue -Confirm:$false

# 작업 동작 정의
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

# 트리거 정의 (부팅 시)
$trigger = New-ScheduledTaskTrigger -AtStartup

# 설정 정의
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# Principal 정의 (SYSTEM 계정)
$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# 작업 등록
Register-ScheduledTask `
    -TaskName "WSL SSH Setup" `
    -Description "부팅 시 WSL SSH 포트 포워딩 자동 설정" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force

Write-Host "✅ 작업 스케줄러 등록 완료!" -ForegroundColor Green
```

**관리자 권한으로 실행:**

```powershell
.\RegisterScheduledTask.ps1
```

**방법 2: GUI로 수동 등록**

1. `Win + R` → `taskschd.msc` 입력
2. **"기본 작업 만들기"** 클릭
3. 이름: `WSL SSH Setup`, 설명: `부팅 시 WSL SSH 포트 포워딩 자동 설정`
4. 트리거: **"컴퓨터를 시작할 때"** 선택
5. 동작: **"프로그램 시작"** 선택
   - 프로그램: `powershell.exe`
   - 인수: `-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Scripts\WSL-SSH-Setup.ps1"`
6. 마침 후 작업을 더블클릭하여 추가 설정:
   - **일반 탭**: "가장 높은 수준의 권한으로 실행" 체크, 사용자를 `SYSTEM`으로 변경
   - **트리거 탭**: "작업 지연 시간" → 30초 설정
   - **구성 대상**: `Windows 10` 선택
   - **설정 탭**:
     - "작업이 실패하면 다시 시작 간격: 1분, 3회"
     - "배터리 전원 사용 시에도 작업 시작"

## 테스트

### 즉시 실행 테스트

```powershell
Start-ScheduledTask -TaskName "WSL SSH Setup"
```

### 설정 확인

```powershell
# 포트 포워딩 확인
netsh interface portproxy show v4tov4

# 방화벽 규칙 확인
Get-NetFirewallRule -DisplayName "WSL SSH*"

# 작업 상태 확인
Get-ScheduledTask -TaskName "WSL SSH Setup" | Get-ScheduledTaskInfo
```

### SSH 접속 테스트

```bash
# 내부망에서
ssh username@로컬IP:60022

# 외부망에서 (공유기 포트포워딩 필요)
ssh username@공인IP:60022
```

## 외부 접속 설정

### 1. 공유기 포트 포워딩

- 외부 포트: `60022`
- 내부 IP: Windows PC의 로컬 IP
- 내부 포트: `60022`

### 2. 공인 IP 확인

```powershell
(Invoke-WebRequest -Uri "https://api.ipify.org").Content
```

또는 https://whatismyipaddress.com 방문

### 3. CGNAT 확인

공유기 외부 IP와 실제 공인 IP가 다르면 CGNAT 환경 → 외부 접속 불가능

## 문제 해결

### 작업 스케줄러가 실행되지 않음

```powershell
# 마지막 실행 결과 확인
Get-ScheduledTask -TaskName "WSL SSH Setup" | Select-Object TaskName, State, LastRunTime, LastTaskResult

# 이벤트 로그 확인
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 20 | 
    Where-Object { $_.Message -like "*WSL SSH Setup*" } | 
    Format-List TimeCreated, Message
```

### SSH 접속이 안 됨

```powershell
# WSL IP 확인
wsl hostname -I

# 포트 리스닝 확인
Test-NetConnection -ComputerName localhost -Port 60022

# WSL 내부 SSH 상태 확인
wsl -e sh -c "service ssh status"
```

### 포트 충돌

```powershell
# 예약된 포트 범위 확인
netsh int ipv4 show excludedportrange tcp
```

## 파라미터

| 파라미터 | 설명 | 기본값 |
|---------|------|--------|
| `-ListenPort` | Windows에서 리스닝할 포트 번호 (1-65535) | `60022` |
| `-Force` | WSL1에서도 강제 실행 | 없음 |

**사용 예:**

```powershell
# 포트 2222 사용
.\WSL-SSH-Setup.ps1 -ListenPort 2222

# WSL1에서 강제 실행
.\WSL-SSH-Setup.ps1 -Force
```

## 주의사항

- Windows 재부팅 시마다 WSL IP가 변경되므로 **반드시 부팅 시 자동 실행 설정** 필요
- 외부 접속 시 **SSH 키 인증** 사용 강력 권장 (비밀번호 인증은 위험)
- CGNAT/이중 NAT 환경에서는 외부 접속 불가능
- 방화벽이 비활성화되어 있으면 방화벽 규칙 추가는 의미 없음

## 라이센스

MIT License

## 기여

이슈 및 PR은 언제나 환영합니다!

## 문의

문제가 발생하면 이슈를 등록해주세요.

---

Made with ❤️ for WSL users
