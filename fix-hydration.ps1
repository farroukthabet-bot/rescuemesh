# RescueMesh: removes the browser-extension hydration error (3 small edits to app\page.tsx).
# From the project root:  powershell -ExecutionPolicy Bypass -File .\fix-hydration.ps1
$ErrorActionPreference = "Stop"
$path = [System.IO.Path]::Combine((Get-Location).Path, "app\page.tsx")
$t = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)

if ($t.Contains("const [mounted, setMounted]")) { Write-Host "Already fixed."; exit 0 }

function Swap($old, $new) {
  if (-not $script:t.Contains($old)) { throw "Could not find: $old" }
  $script:t = $script:t.Replace($old, $new)
}

$a1 = 'const [pending, setPending] = useState(0);'
$a2 = 'useEffect(() => { load().catch((e) => setNotice({ ok: false, text: e.message })); }, [load]);'
$a3 = 'const hederaText = (h: { status?: string } | undefined) =>'

Swap $a1 ($a1 + "`n" + '  const [mounted, setMounted] = useState(false);')
Swap $a2 ('useEffect(() => setMounted(true), []);' + "`n" + '  ' + $a2)
Swap $a3 ('if (!mounted) return <main className="min-h-screen bg-[#F2F4EF]" />;' + "`n`n" + '  ' + $a3)

[System.IO.File]::WriteAllText($path, $t, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Fixed app\page.tsx"
