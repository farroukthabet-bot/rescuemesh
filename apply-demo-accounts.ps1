# RescueMesh: writes DEMO_ACCOUNTS.md into your project and updates the two account scripts.
# From the project root:  powershell -ExecutionPolicy Bypass -File .\apply-demo-accounts.ps1
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
 
function Write-File($rel, $content) {
  $full = [System.IO.Path]::Combine($root, $rel.Replace("/", "\"))
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
  [System.IO.File]::WriteAllText($full, $content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $rel"
}