param(
    [string]$RootUrl = "http://klussert010.nl",
    [string]$MirrorDir = ".\mirror"
)

$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Normalize-Url {
    param(
        [string]$Raw,
        [Uri]$BaseUri
    )

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }

    $candidate = $Raw.Trim().Trim([char[]]"'`"")
    if ($candidate -match '^(#|javascript:|mailto:|tel:|data:)') { return $null }

    if ($candidate.StartsWith("//")) {
        $candidate = "{0}:{1}" -f $BaseUri.Scheme, $candidate
    }

    try {
        if ([Uri]::IsWellFormedUriString($candidate, [UriKind]::Absolute)) {
            $uri = [Uri]$candidate
        }
        else {
            $uri = [Uri]::new($BaseUri, $candidate)
        }
    }
    catch {
        return $null
    }

    if ($uri.Scheme -notin @("http", "https")) { return $null }
    return $uri
}

function Is-SameDomain {
    param([Uri]$Uri, [string]$RootHost)

    $h1 = $Uri.Host.ToLowerInvariant()
    $h2 = $RootHost.ToLowerInvariant()

    if ($h1.StartsWith("www.")) { $h1 = $h1.Substring(4) }
    if ($h2.StartsWith("www.")) { $h2 = $h2.Substring(4) }

    return $h1 -eq $h2
}

function Is-AssetLike {
    param([Uri]$Uri)

    $ext = [System.IO.Path]::GetExtension($Uri.AbsolutePath).ToLowerInvariant()
    if ($ext -in @('.png','.jpg','.jpeg','.gif','.svg','.webp','.avif','.ico','.bmp','.css','.js','.mjs','.woff','.woff2','.ttf','.otf','.eot','.webm','.mp4','.mp3','.wav','.pdf')) {
        return $true
    }

    return $false
}

function Get-AssetLocalPath {
    param(
        [Uri]$Uri,
        [string]$BaseDir
    )

    $rel = $Uri.AbsolutePath.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($rel)) { return $null }

    return (Join-Path $BaseDir ($rel -replace '/', '\\'))
}

$rootUri = [Uri]$RootUrl
$rootHost = $rootUri.Host
$mirrorPath = (Resolve-Path -Path $MirrorDir).Path

$assetUrls = New-Object System.Collections.Generic.HashSet[string]

$htmlFiles = Get-ChildItem -Path $mirrorPath -Recurse -File -Filter *.html
foreach ($file in $htmlFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $pageBase = [Uri]::new($rootUri, ($file.FullName.Substring($mirrorPath.Length) -replace '\\', '/').TrimStart('/'))

    foreach ($m in [regex]::Matches($content, '(?is)(?:src|href|poster|data-src|data-href)\s*=\s*["\x27]([^"\x27]+)["\x27]')) {
        $u = Normalize-Url -Raw $m.Groups[1].Value -BaseUri $pageBase
        if (-not $u) { continue }
        if (-not (Is-SameDomain -Uri $u -RootHost $rootHost)) { continue }
        if (-not (Is-AssetLike -Uri $u)) { continue }
        [void]$assetUrls.Add($u.AbsoluteUri)
    }

    foreach ($m in [regex]::Matches($content, '(?is)srcset\s*=\s*["\x27]([^"\x27]+)["\x27]')) {
        foreach ($part in $m.Groups[1].Value.Split(',')) {
            $candidate = ($part.Trim().Split(' ')[0]).Trim()
            $u = Normalize-Url -Raw $candidate -BaseUri $pageBase
            if (-not $u) { continue }
            if (-not (Is-SameDomain -Uri $u -RootHost $rootHost)) { continue }
            if (-not (Is-AssetLike -Uri $u)) { continue }
            [void]$assetUrls.Add($u.AbsoluteUri)
        }
    }

    foreach ($m in [regex]::Matches($content, '(?is)url\(([^)]+)\)')) {
        $u = Normalize-Url -Raw $m.Groups[1].Value -BaseUri $pageBase
        if (-not $u) { continue }
        if (-not (Is-SameDomain -Uri $u -RootHost $rootHost)) { continue }
        if (-not (Is-AssetLike -Uri $u)) { continue }
        [void]$assetUrls.Add($u.AbsoluteUri)
    }
}

$cssFiles = Get-ChildItem -Path $mirrorPath -Recurse -File -Filter *.css
foreach ($file in $cssFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $relative = ($file.FullName.Substring($mirrorPath.Length) -replace '\\', '/').TrimStart('/')
    $cssBase = [Uri]::new($rootUri, $relative)

    foreach ($m in [regex]::Matches($content, '(?is)url\(([^)]+)\)')) {
        $u = Normalize-Url -Raw $m.Groups[1].Value -BaseUri $cssBase
        if (-not $u) { continue }
        if (-not (Is-SameDomain -Uri $u -RootHost $rootHost)) { continue }
        if (-not (Is-AssetLike -Uri $u)) { continue }
        [void]$assetUrls.Add($u.AbsoluteUri)
    }
}

$downloaded = New-Object System.Collections.Generic.List[string]
$failed = New-Object System.Collections.Generic.List[string]
$already = 0

foreach ($asset in ($assetUrls | Sort-Object)) {
    $uri = [Uri]$asset
    $dest = Get-AssetLocalPath -Uri $uri -BaseDir $mirrorPath
    if (-not $dest) { continue }

    Ensure-Directory -Path (Split-Path -Parent $dest)

    if (Test-Path -LiteralPath $dest) {
        $already++
        continue
    }

    try {
        Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $dest -UseBasicParsing -TimeoutSec 60
        $downloaded.Add($uri.AbsoluteUri)
    }
    catch {
        $failed.Add("{0} -> {1}" -f $uri.AbsoluteUri, $_.Exception.Message)
    }
}

$report = [PSCustomObject]@{
    scanned_html_files = $htmlFiles.Count
    scanned_css_files = $cssFiles.Count
    discovered_asset_urls = $assetUrls.Count
    already_present = $already
    downloaded_missing = $downloaded.Count
    downloaded_urls = $downloaded
    failed_count = $failed.Count
    failed = $failed
}

$reportPath = Join-Path (Split-Path -Parent $mirrorPath) "reports\repair-assets-report.json"
$report | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportPath -Encoding utf8

Write-Output ("Repair complete. Downloaded missing: {0}, failed: {1}, report: {2}" -f $downloaded.Count, $failed.Count, $reportPath)
