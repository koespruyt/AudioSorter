[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [switch]$Help,
  [Parameter(Mandatory=$true)]
  [string]$Source,

  [string]$Target,

  # Profile path relative to repo root (default: profiles/default.json) or absolute path
  [string]$Profile = "profiles/default.json",

  [switch]$Move,
  [switch]$Copy,

  [switch]$OnlineGenreLookup,
  [switch]$DetectBpmFromAudio,

  [ValidateRange(5,60)]
  [int]$AudioBpmSeconds = 10,

  [int]$AudioBpmStartAtSeconds = 30,

  [switch]$RemoveExactDuplicates,
  [switch]$CleanupEmptyDirs
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modPath = Join-Path $here "src\AudioSorter\AudioSorter.psd1"
Import-Module $modPath -Force

if ($Help) {
  Import-Module $modPath -Force
  Get-Help AudioSorter\Invoke-AudioSorter -Full
  return
}
AudioSorter\Invoke-AudioSorter @PSBoundParameters






