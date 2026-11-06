<#
  dsh-phone.ps1 (Windows) —— 把电脑上的 DeepSeek Harness Web 开到星空组网上，手机浏览器直接打开。

  用法（PowerShell，普通用户权限即可；放行防火墙需要管理员）：
      .\dsh-phone.ps1            交互菜单
      .\dsh-phone.ps1 -Start     启动（已在跑就不重启）
      .\dsh-phone.ps1 -Restart   重启，换新 token
      .\dsh-phone.ps1 -Status    看状态
      .\dsh-phone.ps1 -Check     只读自检
      .\dsh-phone.ps1 -Stop      停止
      .\dsh-phone.ps1 -Url       只打印地址

  可选参数：-Port 3081  -Dir C:\code  -Peer 192.168.188.3  -IfMatch 'StarVPN|星空'

  设计要点：
    * 不注册服务、不设开机自启；就是起一个后台进程，用完 -Stop 关掉。
    * token 每次重启才变；不重启时从日志里捞当前地址并校验有效性。
#>
[CmdletBinding()]
param(
  [switch]$Start,
  [switch]$Restart,
  [switch]$Stop,
  [switch]$Status,
  [switch]$Check,
  [switch]$Url,
  [int]$Port = 3081,
  [string]$Dir = $HOME,
  [string]$Peer = '',
  [string]$IfMatch = 'StarVPN|星空|TAP-Windows'
)

$ErrorActionPreference = 'Continue'
$StateDir = Join-Path $env:LOCALAPPDATA 'dsh-mesh'
$UrlFile  = Join-Path $StateDir 'url'
$LogFile  = Join-Path $StateDir 'out.log'
$PidFile  = Join-Path $StateDir 'pid'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Ok($m)   { Write-Host "  OK  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  !   $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  X   $m" -ForegroundColor Red }
function Step($n, $m) { Write-Host "`n[$n] $m" -ForegroundColor Cyan }
function Hr() { Write-Host ('-' * 52) }

function Get-MeshIP {
  $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' }
  $hit = $addrs | Where-Object { $_.InterfaceAlias -match $IfMatch } | Select-Object -First 1
  if (-not $hit) { $hit = $addrs | Where-Object { $_.IPAddress -like '192.168.188.*' } | Select-Object -First 1 }
  if ($hit) { return $hit.IPAddress }
  return $null
}

function Get-DshCmd {
  $c = Get-Command dsh -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $c = Get-Command dsh.cmd -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}

function Test-Listening {
  $l = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  return [bool]$l
}

function Get-ServicePid {
  $l = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($l) { return $l.OwningProcess }
  return $null
}

function Get-UrlFromLog {
  for ($i = 0; $i -lt 45; $i++) {
    if (Test-Path $LogFile) {
      $m = Select-String -Path $LogFile -Pattern "http://[0-9.]+:$Port/\?token=[A-Za-z0-9_-]+" -AllMatches -ErrorAction SilentlyContinue |
           Select-Object -Last 1
      if ($m) {
        $u = $m.Matches[0].Value
        $code = Get-HttpCode $u
        if ($code -eq 200 -or $code -eq 303) {
          Set-Content -Path $UrlFile -Value $u -Encoding ASCII
          return $u
        }
      }
    }
    Start-Sleep -Seconds 1
  }
  return $null
}

function Get-HttpCode($u) {
  try {
    $req = [System.Net.HttpWebRequest]::Create($u)
    $req.AllowAutoRedirect = $false
    $req.Timeout = 5000
    $resp = $req.GetResponse()
    return [int]$resp.StatusCode
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
    return 0
  } catch {
    return 0
  }
}

function Ensure-Firewall {
  $rule = Get-NetFirewallRule -DisplayName "DSH mesh $Port" -ErrorAction SilentlyContinue
  if ($rule) { Ok "防火墙规则已存在（DSH mesh $Port）"; return $true }
  try {
    New-NetFirewallRule -DisplayName "DSH mesh $Port" -Direction Inbound -Protocol TCP `
      -LocalPort $Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
    Ok "已添加入站放行 $Port/tcp"
    return $true
  } catch {
    Warn "添加防火墙规则失败（需要管理员权限）。以管理员 PowerShell 跑一次："
    Write-Host "      New-NetFirewallRule -DisplayName 'DSH mesh $Port' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any"
    return $false
  }
}

function Detect-Peer {
  if ($Peer) { return $Peer }
  $mesh = Get-MeshIP
  if (-not $mesh) { return $null }
  $net = ($mesh -split '\.')[0..2] -join '.'
  $n = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -like "$net.*" -and $_.IPAddress -ne $mesh -and $_.State -ne 'Unreachable' } |
       Select-Object -First 1
  if ($n) { return $n.IPAddress }
  return $null
}

function Do-Start([bool]$Force) {
  Step '0/5' '环境'
  $dsh = Get-DshCmd
  if (-not $dsh) { Bad '找不到 dsh（先 npm i -g @deepseek-ai/dsh）'; return $false }
  Ok "dsh = $dsh"

  Step '1/5' '组网'
  $mesh = Get-MeshIP
  if (-not $mesh) {
    Bad '没找到组网网卡地址（192.168.188.x）。先在星空客户端里点「连接」，再重试。'
    Warn "网卡名对不上时：-IfMatch '<关键字>'；当前网卡："
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } |
      Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize | Out-String | Write-Host
    return $false
  }
  Ok "组网地址 $mesh"

  Step '2/5' '防火墙'
  Ensure-Firewall | Out-Null

  Step '3/5' '启动'
  if ((Test-Listening) -and -not $Force) {
    Ok "已经在运行（不重启，token 保持不变）"
  } else {
    if (Test-Listening) {
      $p = Get-ServicePid
      if ($p) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
    }
    Remove-Item $LogFile -ErrorAction SilentlyContinue
    $args = @('/c', "`"$dsh`" web --host $mesh --port $Port --no-open --trusted-host ${mesh}:${Port} > `"$LogFile`" 2>&1")
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList $args -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
    Set-Content -Path $PidFile -Value $proc.Id -Encoding ASCII
    Start-Sleep -Seconds 3
    if (Test-Listening) { Ok "已启动，监听 ${mesh}:${Port}" } else { Bad "没能监听 ${mesh}:${Port}，日志："; Get-Content $LogFile -Tail 15 -ErrorAction SilentlyContinue; return $false }
  }

  Step '4/5' '取地址'
  $u = Get-UrlFromLog
  if (-not $u) { Bad '没取到有效地址，日志：'; Get-Content $LogFile -Tail 15 -ErrorAction SilentlyContinue; return $false }
  Ok "地址已校验：$u"

  Step '5/5' '手机怎么用'
  Write-Host "      手机浏览器打开上面这个地址（带 token 的那串）一次，之后裸地址 http://${mesh}:${Port}/ 就能用。"
  Write-Host "      二维码：Windows 上没有 qrencode，可以把地址粘到任意在线二维码工具，或直接用手机复制粘贴。"
  Do-Status
  return $true
}

function Do-Stop {
  $p = Get-ServicePid
  if ($p) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue; Ok "已停止（PID $p）" }
  else { Warn "本来就没在运行" }
  Remove-Item $PidFile -ErrorAction SilentlyContinue
}

function Do-Status {
  $mesh = Get-MeshIP
  $svc  = Test-Listening
  Hr
  if ($mesh) { Write-Host " 组网  OK  $mesh" -ForegroundColor Green } else { Write-Host " 组网  X   未连接" -ForegroundColor Red }
  if ($svc)  { Write-Host " 服务  OK  正在监听 :$Port" -ForegroundColor Green } else { Write-Host " 服务  .   没在运行" -ForegroundColor Yellow }
  if ($svc -and (Test-Path $UrlFile)) { Write-Host " 地址  $(Get-Content $UrlFile)" }
  elseif ($svc) { Write-Host " 地址  （刚起，用 -Url 取当前地址）" }
  else { Write-Host " 地址  （服务没运行，旧地址已失效；-Start 启动）" }
  Hr
}

function Do-Url {
  $u = Get-UrlFromLog
  if ($u) { Write-Host $u } else { Bad '没取到有效地址（服务没跑？）' }
}

function Do-Check {
  Step '1/4' '组网'
  $mesh = Get-MeshIP
  if ($mesh) { Ok "组网地址 $mesh" } else { Bad '组网未连接' }

  Step '2/4' '服务'
  if (Test-Listening) { Ok "正在监听 :$Port" } else { Warn "没有监听 :$Port" }

  Step '3/4' '地址'
  if (Test-Path $LogFile) {
    $m = Select-String -Path $LogFile -Pattern "http://[0-9.]+:$Port/\?token=[A-Za-z0-9_-]+" -AllMatches | Select-Object -Last 1
    if ($m) { $code = Get-HttpCode $m.Matches[0].Value; Ok "带 token 访问 -> HTTP $code" } else { Warn '日志里还没有地址' }
  } else { Warn '日志文件不存在（还没启动过）' }

  Step '4/4' '手机可达性'
  $peer = Detect-Peer
  if ($peer) {
    if (Test-Connection -ComputerName $peer -Count 2 -Quiet -ErrorAction SilentlyContinue) { Ok "本机->手机 $peer 可达" }
    else { Warn "ping 不通 $peer（可能手机没连组网，或 ICMP 被防火墙拦）" }
  } else { Warn '没发现对端' }
}

function Show-Menu {
  while ($true) {
    Do-Status
    Write-Host ' 1 启动/出地址   2 重启换 token   3 只显示地址   4 自检   5 停止   0 退出'
    $c = Read-Host ' 选择'
    switch ($c) {
      '1' { Do-Start $false | Out-Null }
      '2' { Do-Start $true  | Out-Null }
      '3' { Do-Url }
      '4' { Do-Check }
      '5' { Do-Stop }
      { $_ -in '0','' } { return }
      default { Warn '没有这个选项' }
    }
  }
}

if ($Start)   { Do-Start $false | Out-Null }
elseif ($Restart) { Do-Start $true | Out-Null }
elseif ($Stop)    { Do-Stop }
elseif ($Status)  { Do-Status }
elseif ($Check)   { Do-Check }
elseif ($Url)     { Do-Url }
else              { Show-Menu }
