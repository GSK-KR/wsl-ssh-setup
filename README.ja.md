# WSL SSH 自動セットアップ

Windows起動時にWSL2 SSHポートフォワーディングを自動設定するPowerShellスクリプト

## 概要

WSL2は再起動するたびにIPアドレスが変更されるため、SSH接続ができなくなります。このスクリプトは：
- Windows起動時に自動的にWSL IPを検出
- ポートフォワーディングルールを自動作成（デフォルト：60022 → WSL:22）
- ファイアウォールを自動設定
- WSLをバックグラウンドで自動実行維持

## 主な機能

- **自動IP検出**：eth0インターフェースから正確なWSL IPを抽出（Dockerブリッジを除外）
- **セキュリティ**：IP Helperサービスの自動チェック、プライベートIPのみ許可
- **SSH自動起動**：3秒待機後に状態確認、必要な場合のみ起動
- **完全なロールバック**：失敗時に追加された設定を自動削除
- **内部/外部ネットワーク対応**：ローカルネットワークとインターネットアクセスの両方に対応
- **安定性**：Mutexによる同時実行防止、すべてのエラー処理

## 要件

- Windows 10/11（PowerShell 3.0以上）
- WSL2のインストールと設定が完了していること
- WSL内にSSHサーバーがインストールされていること（`openssh-server`）
- 管理者権限

## インストール方法

### 1. スクリプトのダウンロード

```powershell
# スクリプト保存フォルダーの作成
New-Item -Path "C:\Scripts" -ItemType Directory -Force

# このリポジトリからスクリプトをダウンロード
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/GSK-KR/wsl-ssh-setup/main/WSL-SSH-Setup.ps1" -OutFile "C:\Scripts\WSL-SSH-Setup.ps1"
```

または手動でダウンロード：
1. `WSL-SSH-Setup.ps1`をダウンロード
2. `C:\Scripts\`フォルダーに保存

### 2. WSLにSSHサーバーをインストール（未インストールの場合）

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install openssh-server -y

# SSHサービスの起動
sudo service ssh start

# 起動時の自動起動（オプション）
sudo systemctl enable ssh
```

### 3. パスワードなしでSSHを起動するsudo設定（推奨）

WSL内で実行：

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/service ssh *, /usr/sbin/service sshd *, /bin/systemctl * ssh, /bin/systemctl * sshd" | sudo tee /etc/sudoers.d/ssh-nopasswd
sudo chmod 440 /etc/sudoers.d/ssh-nopasswd
sudo visudo -c -f /etc/sudoers.d/ssh-nopasswd
```

## 使用方法

### 手動実行

```powershell
# 管理者権限でPowerShellを実行後
C:\Scripts\WSL-SSH-Setup.ps1

# 別のポートを使用する場合
C:\Scripts\WSL-SSH-Setup.ps1 -ListenPort 2222

# WSL1で強制実行する場合
C:\Scripts\WSL-SSH-Setup.ps1 -Force
```

### タスクスケジューラへの自動登録

**方法1：PowerShellによる自動登録（推奨）**

`RegisterScheduledTask.ps1`ファイルを作成し、以下の内容を入力：

```powershell
# 管理者権限の確認
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ 管理者権限で実行してください"
    exit 1
}

# スクリプトパス
$scriptPath = "C:\Scripts\WSL-SSH-Setup.ps1"

# スクリプトファイルの存在確認
if (-not (Test-Path $scriptPath)) {
    Write-Error "❌ スクリプトが見つかりません：$scriptPath"
    exit 1
}

# 既存のタスクを削除
Unregister-ScheduledTask -TaskName "WSL SSH Setup" -ErrorAction SilentlyContinue -Confirm:$false

# タスクアクションの定義
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

# トリガーの定義（起動時）
$trigger = New-ScheduledTaskTrigger -AtStartup

# 設定の定義
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# プリンシパルの定義（SYSTEMアカウント）
$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# タスクの登録
Register-ScheduledTask `
    -TaskName "WSL SSH Setup" `
    -Description "起動時にWSL SSHポートフォワーディングを自動設定" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force

Write-Host "✅ タスクスケジューラの登録完了！" -ForegroundColor Green
```

**管理者権限で実行：**

```powershell
.\RegisterScheduledTask.ps1
```

**方法2：GUIによる手動登録**

1. `Win + R` → `taskschd.msc`を入力
2. **「基本タスクの作成」**をクリック
3. 名前：`WSL SSH Setup`、説明：`起動時にWSL SSHポートフォワーディングを自動設定`
4. トリガー：**「コンピューターの起動時」**を選択
5. 操作：**「プログラムの開始」**を選択
   - プログラム：`powershell.exe`
   - 引数：`-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Scripts\WSL-SSH-Setup.ps1"`
6. 完了後、タスクをダブルクリックして追加設定：
   - **全般タブ**：「最上位の特権で実行する」をチェック、ユーザーを`SYSTEM`に変更
   - **トリガータブ**：「タスクの遅延時間」→30秒を設定
   - **設定対象**：`Windows 10`を選択
   - **設定タブ**：
     - 「タスクが失敗した場合の再起動の間隔：1分、3回」
     - 「バッテリ電源使用時でもタスクを開始する」

## テスト

### 即時実行テスト

```powershell
Start-ScheduledTask -TaskName "WSL SSH Setup"
```

### 設定の確認

```powershell
# ポートフォワーディングの確認
netsh interface portproxy show v4tov4

# ファイアウォールルールの確認
Get-NetFirewallRule -DisplayName "WSL SSH*"

# タスクの状態確認
Get-ScheduledTask -TaskName "WSL SSH Setup" | Get-ScheduledTaskInfo
```

### SSH接続テスト

```bash
# 内部ネットワークから
ssh username@ローカルIP:60022

# 外部ネットワークから（ルーターのポートフォワーディングが必要）
ssh username@グローバルIP:60022
```

## 外部アクセス設定

### 1. ルーターのポートフォワーディング

- 外部ポート：`60022`
- 内部IP：Windows PCのローカルIP
- 内部ポート：`60022`

### 2. グローバルIPの確認

```powershell
(Invoke-WebRequest -Uri "https://api.ipify.org").Content
```

または https://whatismyipaddress.com を訪問

### 3. CGNATの確認

ルーターの外部IPと実際のグローバルIPが異なる場合、CGNAT環境 → 外部アクセス不可

## トラブルシューティング

### タスクスケジューラが実行されない

```powershell
# 最後の実行結果を確認
Get-ScheduledTask -TaskName "WSL SSH Setup" | Select-Object TaskName, State, LastRunTime, LastTaskResult

# イベントログの確認
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 20 |
    Where-Object { $_.Message -like "*WSL SSH Setup*" } |
    Format-List TimeCreated, Message
```

### SSH接続ができない

```powershell
# WSL IPの確認
wsl hostname -I

# ポートリスニングの確認
Test-NetConnection -ComputerName localhost -Port 60022

# WSL内部のSSH状態確認
wsl -e sh -c "service ssh status"
```

### ポート競合

```powershell
# 予約されたポート範囲の確認
netsh int ipv4 show excludedportrange tcp
```

## パラメータ

| パラメータ | 説明 | デフォルト値 |
|-----------|------|-------------|
| `-ListenPort` | Windowsでリスニングするポート番号（1-65535） | `60022` |
| `-Force` | WSL1でも強制実行 | なし |

**使用例：**

```powershell
# ポート2222を使用
.\WSL-SSH-Setup.ps1 -ListenPort 2222

# WSL1で強制実行
.\WSL-SSH-Setup.ps1 -Force
```

## 注意事項

- Windows再起動のたびにWSL IPが変更されるため、**必ず起動時の自動実行設定が必要**
- 外部アクセス時は**SSH鍵認証**の使用を強く推奨（パスワード認証は危険）
- CGNAT/二重NAT環境では外部アクセス不可
- ファイアウォールが無効化されている場合、ファイアウォールルールの追加は無意味

## ライセンス

MIT License

## 貢献

IssueとPRはいつでも歓迎します！

## お問い合わせ

問題が発生した場合は、Issueを登録してください。

---

Made with ❤️ for WSL users
