param(
    [string]$MirrorDir = ".\mirror"
)

$mirrorPath = (Resolve-Path -Path $MirrorDir).Path
$htmlFiles = Get-ChildItem -Path $mirrorPath -Recurse -File -Filter *.html
$missing = New-Object System.Collections.Generic.List[string]
$checked = 0

foreach ($file in $htmlFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8

    foreach ($m in [regex]::Matches($content, '(?is)<img\b[^>]*\bsrc\s*=\s*["\x27]([^"\x27]+)["\x27]')) {
        $u = $m.Groups[1].Value.Trim()
        if ($u.StartsWith('/')) {
            $checked++
            $p = Join-Path $mirrorPath ($u.TrimStart('/') -replace '/', '\\')
            if (-not (Test-Path -LiteralPath $p)) {
                $missing.Add($u)
            }
        }
    }

    foreach ($m in [regex]::Matches($content, '(?is)srcset\s*=\s*["\x27]([^"\x27]+)["\x27]')) {
        foreach ($part in $m.Groups[1].Value.Split(',')) {
            $u = ($part.Trim().Split(' ')[0]).Trim()
            if ($u.StartsWith('/')) {
                $checked++
                $p = Join-Path $mirrorPath ($u.TrimStart('/') -replace '/', '\\')
                if (-not (Test-Path -LiteralPath $p)) {
                    $missing.Add($u)
                }
            }
        }
    }
}

$uniqMissing = $missing | Select-Object -Unique
"checked=$checked"
"missing_count=$($uniqMissing.Count)"
$uniqMissing | Select-Object -First 50
