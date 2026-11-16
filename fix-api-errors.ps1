# RescueMesh: makes API errors readable in the UI (replaces the "Unexpected token <" message).
# From the project root:  powershell -ExecutionPolicy Bypass -File .\fix-api-errors.ps1
$ErrorActionPreference = "Stop"
$path = [System.IO.Path]::Combine((Get-Location).Path, "app\page.tsx")
$t = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
if ($t.Contains("const raw = await res.text();")) { Write-Host "Already fixed."; exit 0 }
$old = '  const data = await res.json();'
if (-not $t.Contains($old)) { throw "Could not find: $old" }
$new = '  const raw = await res.text();' + "`n" +
       '  let data;' + "`n" +
       '  try { data = JSON.parse(raw); } catch {' + "`n" +
       '    throw new Error(`${method} ${path} returned HTTP ${res.status} (not JSON). Look at the npm run dev terminal for the real error.`);' + "`n" +
       '  }'
$t = $t.Replace($old, $new)
[System.IO.File]::WriteAllText($path, $t, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Fixed app\page.tsx"
