[CmdletBinding(DefaultParameterSetName = "Install")]
param(
  [Parameter(Mandatory = $true, ParameterSetName = "Install")]
  [switch]$Install,

  [Parameter(Mandatory = $true, ParameterSetName = "Uninstall")]
  [switch]$Uninstall,

  [Parameter(Mandatory = $true, ParameterSetName = "Install")]
  [ValidatePattern('^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$')]
  [string]$Ship,

  [Parameter(Mandatory = $true, ParameterSetName = "Install")]
  [string]$TinRelay,

  [Parameter(Mandatory = $true, ParameterSetName = "Install")]
  [string]$Bridge,

  [Parameter(ParameterSetName = "Install")]
  [string]$CodexHome,

  [Parameter(ParameterSetName = "Install")]
  [string]$RoutingFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RadioTask = "space.tinrelay.radio"
$BridgeTask = "space.tinrelay.codex-bridge"
$TaskPath = "\"

function Get-TinRelayTask {
  param([Parameter(Mandatory = $true)][string]$Name)

  Get-ScheduledTask -TaskName $Name -TaskPath $TaskPath -ErrorAction SilentlyContinue
}

function Stop-TinRelayTask {
  param([Parameter(Mandatory = $true)][string]$Name)

  $task = Get-TinRelayTask -Name $Name
  if ($null -eq $task) {
    return
  }

  Disable-ScheduledTask -TaskName $Name -TaskPath $TaskPath | Out-Null
  $task = Get-TinRelayTask -Name $Name
  if ($task.State -ne "Running") {
    return
  }

  Stop-ScheduledTask -TaskName $Name -TaskPath $TaskPath
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 100
    $task = Get-TinRelayTask -Name $Name
  } while ($null -ne $task -and $task.State -eq "Running" -and
    [DateTime]::UtcNow -lt $deadline)

  if ($null -ne $task -and $task.State -eq "Running") {
    throw "scheduled task did not stop: $Name"
  }
}

function Resolve-TinRelayFile {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $item = Get-Item -LiteralPath $Value -ErrorAction Stop
  if (-not ($item -is [System.IO.FileInfo])) {
    throw "$Label is not a file: $Value"
  }
  $item.FullName
}

function Resolve-TinRelayDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $item = Get-Item -LiteralPath $Value -ErrorAction Stop
  if (-not ($item -is [System.IO.DirectoryInfo])) {
    throw "$Label is not a directory: $Value"
  }
  $item.FullName
}

function ConvertTo-TinRelayArgument {
  param([Parameter(Mandatory = $true)][string]$Value)

  if ($Value.Contains('"')) {
    throw "Windows command arguments cannot contain a quote"
  }
  $escaped = [Regex]::Replace($Value, '(\\+)$', '$1$1')
  '"' + $escaped + '"'
}

function Register-TinRelayTask {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$UserName,
    [Parameter(Mandatory = $true)][string]$UserSid
  )

  $argumentLine = ($Arguments | ForEach-Object {
    ConvertTo-TinRelayArgument -Value $_
  }) -join " "

  $TaskCreateOrUpdate = 6
  $TaskLogonS4U = 2
  $TaskActionExecute = 0
  $TaskTriggerTime = 1
  $TaskTriggerLogon = 9
  $TaskInstancesIgnoreNew = 2
  $TaskRunLevelLimited = 0

  $scheduler = New-Object -ComObject "Schedule.Service"
  $scheduler.Connect()
  $definition = $scheduler.NewTask(0)
  $definition.Principal.UserId = $UserSid
  $definition.Principal.LogonType = $TaskLogonS4U
  $definition.Principal.RunLevel = $TaskRunLevelLimited

  $definition.Settings.AllowDemandStart = $true
  $definition.Settings.DisallowStartIfOnBatteries = $false
  $definition.Settings.Enabled = $true
  $definition.Settings.ExecutionTimeLimit = "PT0S"
  $definition.Settings.MultipleInstances = $TaskInstancesIgnoreNew
  $definition.Settings.StartWhenAvailable = $true
  $definition.Settings.StopIfGoingOnBatteries = $false

  $logonTrigger = $definition.Triggers.Create($TaskTriggerLogon)
  $logonTrigger.UserId = $UserName

  $watchdogTrigger = $definition.Triggers.Create($TaskTriggerTime)
  $watchdogTrigger.StartBoundary = [DateTime]::Now.AddSeconds(5).ToString("s")
  $watchdogTrigger.Repetition.Interval = "PT1M"
  $watchdogTrigger.Repetition.StopAtDurationEnd = $false

  $action = $definition.Actions.Create($TaskActionExecute)
  $action.Path = $Executable
  $action.Arguments = $argumentLine
  $action.WorkingDirectory = [System.IO.Path]::GetDirectoryName($Executable)

  $root = $scheduler.GetFolder($TaskPath)
  [void]$root.RegisterTaskDefinition(
    $Name,
    $definition,
    $TaskCreateOrUpdate,
    $UserName,
    $null,
    $TaskLogonS4U,
    $null
  )
}

if ($Uninstall) {
  foreach ($name in @($BridgeTask, $RadioTask)) {
    if ($null -ne (Get-TinRelayTask -Name $name)) {
      Stop-TinRelayTask -Name $name
      Unregister-ScheduledTask -TaskName $name -TaskPath $TaskPath -Confirm:$false
    }
  }
  Write-Output "removed"
  exit 0
}

$profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
if ([string]::IsNullOrWhiteSpace($profile)) {
  throw "current user profile is unavailable"
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
  $CodexHome = Join-Path $profile ".codex"
}
if ([string]::IsNullOrWhiteSpace($RoutingFile)) {
  $RoutingFile = Join-Path $profile ".config\tinrelay\$Ship\codex-addresses.json"
}

$TinRelay = Resolve-TinRelayFile -Value $TinRelay -Label "TinRelay executable"
$Bridge = Resolve-TinRelayFile -Value $Bridge -Label "bridge executable"
$CodexHome = Resolve-TinRelayDirectory -Value $CodexHome -Label "Codex home"
$RoutingFile = Resolve-TinRelayFile -Value $RoutingFile -Label "routing file"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($null -eq $identity.User) {
  throw "current user SID is unavailable"
}

foreach ($name in @($BridgeTask, $RadioTask)) {
  Stop-TinRelayTask -Name $name
}

Register-TinRelayTask -Name $RadioTask -Executable $TinRelay -Arguments @(
  "--ship", $Ship, "radio", "collect"
) -UserName $identity.Name -UserSid $identity.User.Value
Register-TinRelayTask -Name $BridgeTask -Executable $Bridge -Arguments @(
  "run", "--ship", $Ship, "--routing-file", $RoutingFile,
  "--tinrelay", $TinRelay, "--codex-home", $CodexHome
) -UserName $identity.Name -UserSid $identity.User.Value

Start-ScheduledTask -TaskName $RadioTask -TaskPath $TaskPath
Start-ScheduledTask -TaskName $BridgeTask -TaskPath $TaskPath
Write-Output "installed"
