Describe "AudioSorter smoke" {
  It "Module manifest exists" {
    Test-Path (Join-Path $PSScriptRoot "..\src\AudioSorter\AudioSorter.psd1") | Should -BeTrue
  }

  It "Module imports and exports Invoke-AudioSorter" {
    Import-Module (Join-Path $PSScriptRoot "..\src\AudioSorter\AudioSorter.psd1") -Force
    (Get-Command Invoke-AudioSorter -ErrorAction Stop).CommandType | Should -Be 'Function'
  }
}
