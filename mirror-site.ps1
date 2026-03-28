param(
    [string]$RootUrl = "http://klussert010.nl",
    [string]$ProjectDir = "."
)

$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-Md5 {
    param([string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $md5.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $md5.Dispose()
    }
}

function Normalize-Url {
    param(
        [string]$Raw,
        [Uri]$BaseUri
    )

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $null
    }

    $candidate = $Raw.Trim().Trim([char[]]"'`"")
    if ($candidate -match '^(#|javascript:|mailto:|tel:|data:)') {
        return $null
    }

    if ($candidate.StartsWith("//")) {
        $candidate = "$($BaseUri.Scheme):$candidate"
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

    if (-not $uri.IsAbsoluteUri) {
        return $null
    }

    if ($uri.Scheme -notin @("http", "https")) {
        return $null
    }

    if ($uri.Fragment) {
        $builder = [UriBuilder]::new($uri)
        $builder.Fragment = ""
        $uri = $builder.Uri
    }

    return $uri
}

function Is-SameDomain {
    param(
        [Uri]$Uri,
        [string]$RootHost
    )

    if (-not $Uri) { return $false }

    $h1 = $Uri.Host.ToLowerInvariant()
    $h2 = $RootHost.ToLowerInvariant()

    $n1 = if ($h1.StartsWith("www.")) { $h1.Substring(4) } else { $h1 }
    $n2 = if ($h2.StartsWith("www.")) { $h2.Substring(4) } else { $h2 }

    return $n1 -eq $n2
}

function Get-WebText {
    param([Uri]$Uri)
    try {
        return (Invoke-WebRequest -Uri $Uri.AbsoluteUri -UseBasicParsing -TimeoutSec 60).Content
    }
    catch {
        throw "Download mislukt: $($Uri.AbsoluteUri) - $($_.Exception.Message)"
    }
}

function Save-TextUtf8NoBom {
    param(
        [string]$Path,
        [string]$Text
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Get-PageLocalPath {
    param(
        [Uri]$Uri,
        [string]$BaseDir
    )

    $segments = @($Uri.AbsolutePath.TrimStart('/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries))
    $folder = if ($segments.Count -gt 0) {
        Join-Path $BaseDir ($segments -join '\\')
    }
    else {
        $BaseDir
    }

    return (Join-Path $folder "index.html")
}

function Get-AssetLocalPath {
    param(
        [Uri]$Uri,
        [string]$BaseDir
    )

    $rel = $Uri.AbsolutePath.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($rel)) {
        $rel = "index"
    }

    if ($rel.EndsWith('/')) {
        $rel += "index"
    }

    if (-not [System.IO.Path]::HasExtension($rel)) {
        $rel += ".bin"
    }

    return (Join-Path $BaseDir $rel)
}

function Is-AssetLikeUrl {
    param([Uri]$Uri)

    $ext = [System.IO.Path]::GetExtension($Uri.AbsolutePath).ToLowerInvariant()
    if ($ext -in @('.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.avif', '.ico', '.bmp', '.js', '.mjs', '.css', '.woff', '.woff2', '.ttf', '.otf', '.eot', '.webm', '.mp4', '.mp3', '.wav', '.pdf')) {
        return $true
    }

    return $false
}

function Add-BaseTagToHtml {
    param(
        [string]$Html,
        [string]$BaseHref
    )

    if ($Html -match '(?is)<head\b[^>]*>') {
        return [regex]::Replace(
            $Html,
            '(?is)(<head\b[^>]*>)',
            "$1`r`n<base href=""$BaseHref"">",
            1
        )
    }

    return $Html
}

function Extract-AssetUrlsFromHtml {
    param(
        [string]$Html,
        [Uri]$PageUri
    )

    $result = New-Object System.Collections.Generic.HashSet[string]

    $attrPattern = '(?is)(?:src|href|poster|data-src|data-href)\s*=\s*["\x27]([^"\x27]+)["\x27]'
    foreach ($m in [regex]::Matches($Html, $attrPattern)) {
        $u = Normalize-Url -Raw $m.Groups[1].Value -BaseUri $PageUri
        if ($u) { [void]$result.Add($u.AbsoluteUri) }
    }

    $srcsetPattern = '(?is)srcset\s*=\s*["\x27]([^"\x27]+)["\x27]'
    foreach ($m in [regex]::Matches($Html, $srcsetPattern)) {
        $parts = $m.Groups[1].Value.Split(',')
        foreach ($part in $parts) {
            $candidate = ($part.Trim().Split(' ')[0]).Trim()
            $u = Normalize-Url -Raw $candidate -BaseUri $PageUri
            if ($u) { [void]$result.Add($u.AbsoluteUri) }
        }
    }

    $styleUrlPattern = '(?is)url\(([^)]+)\)'
    foreach ($m in [regex]::Matches($Html, $styleUrlPattern)) {
        $raw = $m.Groups[1].Value.Trim().Trim([char[]]"'`"")
        $u = Normalize-Url -Raw $raw -BaseUri $PageUri
        if ($u) { [void]$result.Add($u.AbsoluteUri) }
    }

    return $result
}

function Extract-UrlsFromCss {
    param(
        [string]$Css,
        [Uri]$CssUri
    )

    $result = New-Object System.Collections.Generic.HashSet[string]
    $pattern = '(?is)url\(([^)]+)\)'

    foreach ($m in [regex]::Matches($Css, $pattern)) {
        $raw = $m.Groups[1].Value.Trim().Trim([char[]]"'`"")
        $u = Normalize-Url -Raw $raw -BaseUri $CssUri
        if ($u) { [void]$result.Add($u.AbsoluteUri) }
    }

    return $result
}

function Get-Sitemaps {
    param([Uri]$RootUri)

    $candidates = @(
        "/sitemap.xml",
        "/sitemap_index.xml",
        "/wp-sitemap.xml"
    )

    $valid = @()
    foreach ($p in $candidates) {
        $u = [Uri]::new($RootUri, $p)
        try {
            $content = Get-WebText -Uri $u
            if ($content -match '<urlset|<sitemapindex|<\?xml') {
                $valid += $u.AbsoluteUri
            }
        }
        catch {
            continue
        }
    }

    return ($valid | Select-Object -Unique)
}

function Collect-PageUrlsFromSitemap {
    param(
        [string[]]$SitemapUrls,
        [string]$RootHost
    )

    $visited = New-Object System.Collections.Generic.HashSet[string]
    $pages = New-Object System.Collections.Generic.HashSet[string]
    $queue = [System.Collections.Generic.Queue[string]]::new()

    foreach ($s in $SitemapUrls) { $queue.Enqueue($s) }

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $visited.Add($current)) {
            continue
        }

        try {
            $xmlText = (Invoke-WebRequest -Uri $current -UseBasicParsing -TimeoutSec 60).Content
            [xml]$xml = $xmlText
        }
        catch {
            continue
        }

        $sitemapNodes = @($xml.SelectNodes("//*[local-name()='sitemap']/*[local-name()='loc']"))
        if ($sitemapNodes.Count -gt 0) {
            foreach ($node in $sitemapNodes) {
                if ($node.InnerText) { $queue.Enqueue($node.InnerText.Trim()) }
            }
            continue
        }

        $urlNodes = @($xml.SelectNodes("//*[local-name()='url']/*[local-name()='loc']"))
        foreach ($node in $urlNodes) {
            $loc = $node.InnerText.Trim()
            try {
                $uri = [Uri]$loc
                if (Is-SameDomain -Uri $uri -RootHost $RootHost) {
                    [void]$pages.Add($uri.AbsoluteUri)
                }
            }
            catch {
                continue
            }
        }
    }

    return ($pages | Sort-Object)
}

function Get-AssetType {
    param([string]$Path)

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    if ($ext -in @('.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.avif', '.ico', '.bmp')) { return 'images' }
    if ($ext -in @('.js', '.mjs')) { return 'js' }
    if ($ext -in @('.css')) { return 'css' }
    if ($ext -in @('.woff', '.woff2', '.ttf', '.otf', '.eot')) { return 'fonts' }
    return 'other'
}

$rootUri = [Uri]$RootUrl
$rootHost = $rootUri.Host

$projectPath = (Resolve-Path -Path $ProjectDir).Path
$mirrorRoot = Join-Path $projectPath "mirror"
$reportDir = Join-Path $projectPath "reports"
Ensure-Directory -Path $mirrorRoot
Ensure-Directory -Path $reportDir

$failedDownloads = New-Object System.Collections.Generic.List[string]
$rewrittenFiles = New-Object System.Collections.Generic.List[string]

# Step 1 - Analyse
$homepageHtml = Get-WebText -Uri $rootUri
$homepagePath = Join-Path $reportDir "homepage-live.html"
Save-TextUtf8NoBom -Path $homepagePath -Text $homepageHtml

$homepageCss = @([regex]::Matches($homepageHtml, '(?is)<link[^>]+href=["\x27]([^"\x27]+\.css[^"\x27]*)["\x27]') | ForEach-Object { $_.Groups[1].Value })
$homepageJs = @([regex]::Matches($homepageHtml, '(?is)<script[^>]+src=["\x27]([^"\x27]+)["\x27]') | ForEach-Object { $_.Groups[1].Value })

$cms = "Onbekend"
if ($homepageHtml -match 'wp-content|wp-includes|wordpress') { $cms = "WordPress" }
elseif ($homepageHtml -match 'elementor') { $cms = "Elementor" }
elseif ($homepageHtml -match 'neve') { $cms = "Neve" }
elseif ($homepageHtml -match 'cm4all') { $cms = "cm4all" }
elseif ($homepageHtml -match 'wix') { $cms = "Wix" }

$rootRelativeHints = @()
if ($homepageHtml -match '/\.cm4all/') { $rootRelativeHints += '/.cm4all/' }
if ($homepageHtml -match '/assets/') { $rootRelativeHints += '/assets/' }
if ($homepageHtml -match '/wp-content/') { $rootRelativeHints += '/wp-content/' }

$sitemapCandidates = Get-Sitemaps -RootUri $rootUri

# Step 2 - Mirror pages from sitemap
$pageUrls = Collect-PageUrlsFromSitemap -SitemapUrls $sitemapCandidates -RootHost $rootHost
if ($pageUrls.Count -eq 0) {
    $pageUrls = @($rootUri.AbsoluteUri)
}
elseif ($pageUrls -notcontains $rootUri.AbsoluteUri) {
    $pageUrls = @($rootUri.AbsoluteUri) + $pageUrls
}

$pageManifest = @()
foreach ($url in $pageUrls) {
    try {
        $uri = [Uri]$url
        $html = Get-WebText -Uri $uri
        $html = Add-BaseTagToHtml -Html $html -BaseHref ("https://{0}/" -f $rootHost)

        $localPath = Get-PageLocalPath -Uri $uri -BaseDir $mirrorRoot
        Save-TextUtf8NoBom -Path $localPath -Text $html

        $pageManifest += [PSCustomObject]@{
            url = $uri.AbsoluteUri
            file = $localPath
        }
    }
    catch {
        $failedDownloads.Add("PAGE: $url -> $($_.Exception.Message)")
    }
}

$pageManifestPath = Join-Path $reportDir "page-manifest.json"
($pageManifest | ConvertTo-Json -Depth 4) | Out-File -FilePath $pageManifestPath -Encoding utf8

# Step 3 - Download assets from mirrored HTML + CSS
$assetUrls = New-Object System.Collections.Generic.HashSet[string]

foreach ($p in $pageManifest) {
    $html = Get-Content -LiteralPath $p.file -Raw -Encoding UTF8
    $uri = [Uri]$p.url
    $found = Extract-AssetUrlsFromHtml -Html $html -PageUri $uri
    foreach ($f in $found) {
        $u = [Uri]$f
        if (Is-SameDomain -Uri $u -RootHost $rootHost) {
            if (-not (Is-AssetLikeUrl -Uri $u)) { continue }
            [void]$assetUrls.Add($u.AbsoluteUri)
        }
    }
}

$downloadedAssets = @()
$cssAssetMeta = @()
foreach ($asset in ($assetUrls | Sort-Object)) {
    try {
        $uri = [Uri]$asset
        $dest = Get-AssetLocalPath -Uri $uri -BaseDir $mirrorRoot
        Ensure-Directory -Path (Split-Path -Parent $dest)

        Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $dest -UseBasicParsing -TimeoutSec 60

        $type = Get-AssetType -Path $dest
        $meta = [PSCustomObject]@{
            url = $uri.AbsoluteUri
            file = $dest
            type = $type
        }
        $downloadedAssets += $meta

        if ($type -eq 'css') {
            $cssAssetMeta += $meta
        }
    }
    catch {
        $failedDownloads.Add("ASSET: $asset -> $($_.Exception.Message)")
    }
}

# Parse downloaded CSS files for nested url() assets
$extraAssetUrls = New-Object System.Collections.Generic.HashSet[string]
foreach ($css in $cssAssetMeta) {
    try {
        $cssText = Get-Content -LiteralPath $css.file -Raw -Encoding UTF8
        $cssUri = [Uri]$css.url
        $nested = Extract-UrlsFromCss -Css $cssText -CssUri $cssUri
        foreach ($n in $nested) {
            $u = [Uri]$n
            if (Is-SameDomain -Uri $u -RootHost $rootHost) {
                if (-not (Is-AssetLikeUrl -Uri $u)) { continue }
                [void]$extraAssetUrls.Add($u.AbsoluteUri)
            }
        }
    }
    catch {
        continue
    }
}

foreach ($asset in ($extraAssetUrls | Sort-Object)) {
    if ($assetUrls.Contains($asset)) { continue }

    try {
        $uri = [Uri]$asset
        $dest = Get-AssetLocalPath -Uri $uri -BaseDir $mirrorRoot
        Ensure-Directory -Path (Split-Path -Parent $dest)

        Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $dest -UseBasicParsing -TimeoutSec 60

        $type = Get-AssetType -Path $dest
        $downloadedAssets += [PSCustomObject]@{
            url = $uri.AbsoluteUri
            file = $dest
            type = $type
        }
        [void]$assetUrls.Add($asset)
    }
    catch {
        $failedDownloads.Add("ASSET_CSS_NESTED: $asset -> $($_.Exception.Message)")
    }
}

$assetManifestPath = Join-Path $reportDir "asset-manifest.json"
($downloadedAssets | ConvertTo-Json -Depth 4) | Out-File -FilePath $assetManifestPath -Encoding utf8

# Step 4 - Rewrite paths
$domainVariants = New-Object System.Collections.Generic.HashSet[string]
[void]$domainVariants.Add($rootHost.ToLowerInvariant())
if ($rootHost.ToLowerInvariant().StartsWith("www.")) {
    [void]$domainVariants.Add($rootHost.ToLowerInvariant().Substring(4))
}
else {
    [void]$domainVariants.Add(("www.{0}" -f $rootHost.ToLowerInvariant()))
}

$allHtmlFiles = Get-ChildItem -Path $mirrorRoot -Recurse -File -Filter *.html
$allCssFiles = Get-ChildItem -Path $mirrorRoot -Recurse -File -Filter *.css
$allJsFiles = Get-ChildItem -Path $mirrorRoot -Recurse -File -Filter *.js

foreach ($file in $allHtmlFiles) {
    $txt = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $orig = $txt

    foreach ($d in $domainVariants) {
        $esc = [regex]::Escape($d)
        $txt = [regex]::Replace($txt, "(?i)https?://$esc/", "/")
        $txt = [regex]::Replace($txt, "(?i)//$esc/", "/")
    }

    $txt = [regex]::Replace($txt, '(?is)<base\s+href=["\x27][^"\x27]*["\x27]\s*/?>', '<base href="/">', 1)

    if ($txt -ne $orig) {
        Save-TextUtf8NoBom -Path $file.FullName -Text $txt
        $rewrittenFiles.Add($file.FullName)
    }
}

foreach ($file in @(@($allCssFiles) + @($allJsFiles))) {
    $txt = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $orig = $txt

    foreach ($d in $domainVariants) {
        $esc = [regex]::Escape($d)
        $txt = [regex]::Replace($txt, "(?i)https?://$esc/", "/")
        $txt = [regex]::Replace($txt, "(?i)//$esc/", "/")
    }

    if ($txt -ne $orig) {
        Save-TextUtf8NoBom -Path $file.FullName -Text $txt
        $rewrittenFiles.Add($file.FullName)
    }
}

# Step 5 - Verify
$verification = @()
foreach ($file in $allHtmlFiles) {
    $txt = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8

    $hasBase = $txt -match '(?is)<base\s+href=["\x27]/["\x27]\s*/?>'
    $hasScript = $txt -match '(?is)<script\b'
    $hasStyle = ($txt -match '(?is)<style\b') -or ($txt -match '(?is)<link\b[^>]*rel=["\x27][^"\x27]*stylesheet')
    $endsHtml = $txt.TrimEnd().ToLowerInvariant().EndsWith('</html>')

    $hasAbsolute = $false
    foreach ($d in $domainVariants) {
        $esc = [regex]::Escape($d)
        if ($txt -match "(?i)https?://$esc/") {
            $hasAbsolute = $true
            break
        }
    }

    $verification += [PSCustomObject]@{
        file = $file.FullName
        base_ok = $hasBase
        script_ok = $hasScript
        style_ok = $hasStyle
        html_closed = $endsHtml
        no_abs_domain_refs = -not $hasAbsolute
    }
}

$verificationPath = Join-Path $reportDir "verification.json"
($verification | ConvertTo-Json -Depth 4) | Out-File -FilePath $verificationPath -Encoding utf8

# Step 6 - Report
$typeCounts = $downloadedAssets | Group-Object -Property type | ForEach-Object {
    [PSCustomObject]@{ type = $_.Name; count = $_.Count }
}

$remainingOnline = New-Object System.Collections.Generic.HashSet[string]
foreach ($file in $allHtmlFiles) {
    $txt = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    foreach ($m in [regex]::Matches($txt, '(?is)https?://[^"''\s>]+')) {
        $u = $m.Value
        try {
            $uri = [Uri]$u
            if (-not (Is-SameDomain -Uri $uri -RootHost $rootHost)) {
                [void]$remainingOnline.Add($uri.GetLeftPart([System.UriPartial]::Path))
            }
        }
        catch {
            continue
        }
    }
}

$analysis = [PSCustomObject]@{
    root_url = $rootUri.AbsoluteUri
    detected_cms_or_theme = $cms
    homepage_css_refs = ($homepageCss | Select-Object -Unique)
    homepage_js_refs = ($homepageJs | Select-Object -Unique)
    root_relative_hints = ($rootRelativeHints | Select-Object -Unique)
    sitemap_candidates_found = $sitemapCandidates
    sitemap_used_count = $sitemapCandidates.Count
}

$summary = [PSCustomObject]@{
    analysis = $analysis
    mirrored_html_pages = $pageManifest.Count
    downloaded_assets_total = $downloadedAssets.Count
    downloaded_assets_by_type = $typeCounts
    failed_downloads = $failedDownloads
    rewritten_files_count = $rewrittenFiles.Count
    rewritten_files = ($rewrittenFiles | Select-Object -Unique)
    remaining_online_dependencies = ($remainingOnline | Sort-Object)
    verify_pass_count = @($verification | Where-Object {
        $_.base_ok -and $_.script_ok -and $_.style_ok -and $_.html_closed -and $_.no_abs_domain_refs
    }).Count
    verify_total = $verification.Count
    project_dir = $projectPath
    mirror_dir = $mirrorRoot
    open_local_instruction = "Open een lokale webserver in map '$mirrorRoot' (bijv. VS Code Live Server) en start bij /index.html"
}

$reportJsonPath = Join-Path $reportDir "migration-report.json"
($summary | ConvertTo-Json -Depth 8) | Out-File -FilePath $reportJsonPath -Encoding utf8

$reportTxtPath = Join-Path $reportDir "migration-report.txt"
@(
    "MIGRATIE RAPPORT",
    "================",
    "Root URL: $($analysis.root_url)",
    "Gedetecteerd CMS/thema: $($analysis.detected_cms_or_theme)",
    "Sitemap candidates: $($analysis.sitemap_candidates_found -join ', ')",
    "Mirrored HTML paginas: $($summary.mirrored_html_pages)",
    "Gedownloade assets totaal: $($summary.downloaded_assets_total)",
    "Assets per type:",
    ($typeCounts | ForEach-Object { "- $($_.type): $($_.count)" }),
    "Mislukte downloads: $($failedDownloads.Count)",
    ($failedDownloads | ForEach-Object { "- $_" }),
    "Herschreven bestanden: $($summary.rewritten_files_count)",
    "Verificatie geslaagd: $($summary.verify_pass_count)/$($summary.verify_total)",
    "Resterende online afhankelijkheden:",
    ($remainingOnline | Sort-Object | ForEach-Object { "- $_" }),
    "Lokaal openen:",
    $summary.open_local_instruction
) | Out-File -FilePath $reportTxtPath -Encoding utf8

Write-Output "Klaar. Rapport: $reportJsonPath"
Write-Output "Tekstrapport: $reportTxtPath"
Write-Output "Mirror map: $mirrorRoot"