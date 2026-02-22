Describe "AudioSorter smoke" {

  It "Module can be imported" {
    $mod = Join-Path $PSScriptRoot "..\src\AudioSorter\AudioSorter.psd1"
    Test-Path $mod | Should -BeTrue
    Import-Module $mod -Force
  }

  It "Invoke-AudioSorter command exists" {
    (Get-Command Invoke-AudioSorter -ErrorAction Stop).CommandType | Should -Be 'Function'
  }
}
