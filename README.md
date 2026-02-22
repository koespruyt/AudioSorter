Describe 'AudioSorter' {
  It 'Module imports' {
    $mod = Join-Path $PSScriptRoot '..\src\AudioSorter\AudioSorter.psd1'
    { Import-Module $mod -Force } | Should -Not -Throw
  }
}
