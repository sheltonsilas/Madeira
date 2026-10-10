# Keep the machine awake while the overnight driver runs.
#
# Why: the driver only dispatches GitHub Actions runs and polls their status.
# Every expensive minute is spent on GitHub's runners, but the two things that
# can stop the loop are both local -- Windows deciding the machine is idle, and
# Windows deciding the display may turn off and (on Modern Standby machines)
# putting the whole system into a low-power state where a one-minute poll turns
# into a multi-hour gap.
#
# SetThreadExecutionState is the documented, unprivileged way to say "this
# system is busy". ES_CONTINUOUS makes the request last until the process exits,
# ES_SYSTEM_REQUIRED keeps the system running. The display is deliberately NOT
# requested (no ES_DISPLAY_REQUIRED): the screen may go dark, which is what a
# locked laptop does anyway, but the machine stays up.
#
# The flag is re-asserted every two minutes rather than once, because a single
# call is easy for a machine that has just resumed to lose track of, and this
# costs nothing.
#
# It cannot override a lid-close action configured as "sleep" on battery: that
# is a power policy, not an idle decision, and changing it needs an elevated
# powercfg. Closing the lid is therefore the one case that will pause the loop
# until the machine is opened again. The loop is written to survive that: it
# reads conclusions from the API, so a run it slept through is simply noticed
# later.
param(
    [string]$LogFile = "$PSScriptRoot\overnight\keep-awake.log"
)

Add-Type -Namespace MadeiraKeepAwake -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

$ES_CONTINUOUS = 0x80000000
$ES_SYSTEM_REQUIRED = 0x00000001
$flags = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED

$dir = Split-Path -Parent $LogFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

"$(Get-Date -Format o) keep-awake started (flags 0x{0:x})" -f $flags | Out-File -Append -Encoding utf8 $LogFile

while ($true) {
    $rc = [MadeiraKeepAwake.Native]::SetThreadExecutionState($flags)
    if ($rc -eq 0) {
        "$(Get-Date -Format o) SetThreadExecutionState failed (last error $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message))" |
            Out-File -Append -Encoding utf8 $LogFile
    }
    Start-Sleep -Seconds 120
}
