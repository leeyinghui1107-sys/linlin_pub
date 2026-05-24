<#
.SYNOPSIS
Publishes tocomini build artifacts from dist/ to GitHub and Gitee releases.

.DESCRIPTION
The script uses GitHub CLI for GitHub releases and Gitee OpenAPI for Gitee
releases. Existing same-name release assets are skipped; missing assets are
uploaded.

.EXAMPLE
$env:GITEE_TOKEN = "your-gitee-token"
powershell -ExecutionPolicy Bypass -File .\publish-release.ps1 -Tag v1.3.6
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [string]$Title,

    [string]$GitHubRepo,

    [string]$GiteeRepo,

    [string]$GiteeToken,

    [string]$DistPath,

    [string]$Notes,

    [string]$NotesFile,

    [string]$TargetCommitish = "master",

    [switch]$Prerelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Require-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$InstallHint
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Command '$Name' was not found. $InstallHint"
    }
}

function Get-RemoteUrl {
    param([Parameter(Mandatory = $true)][string]$RemoteName)

    $url = (& git remote get-url $RemoteName 2>$null)
    if (-not $url) {
        return $null
    }

    return $url.Trim()
}

function Parse-RemoteRepo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl,

        [Parameter(Mandatory = $true)]
        [string]$HostName
    )

    $escapedHost = [regex]::Escape($HostName)

    if ($RemoteUrl -match "^git@$escapedHost`:(?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$") {
        return "$($Matches.owner)/$($Matches.repo)"
    }

    if ($RemoteUrl -match "^https://$escapedHost/(?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?/?$") {
        return "$($Matches.owner)/$($Matches.repo)"
    }

    if ($RemoteUrl -match "^http://$escapedHost/(?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?/?$") {
        return "$($Matches.owner)/$($Matches.repo)"
    }

    return $null
}

function Resolve-RemoteRepo {
    param(
        [string]$RepoValue,
        [Parameter(Mandatory = $true)][string]$RemoteName,
        [Parameter(Mandatory = $true)][string]$HostName
    )

    if ($RepoValue) {
        return $RepoValue
    }

    $remoteUrl = Get-RemoteUrl -RemoteName $RemoteName
    if (-not $remoteUrl) {
        throw "Git remote '$RemoteName' was not found. Pass the repository as owner/repo."
    }

    $repo = Parse-RemoteRepo -RemoteUrl $remoteUrl -HostName $HostName
    if (-not $repo) {
        throw "Unable to parse $HostName repository from remote '$RemoteName': $remoteUrl"
    }

    return $repo
}

function Split-Repo {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $parts = $Repo.Split("/")
    if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) {
        throw "Repository must use owner/repo format: $Repo"
    }

    return @{
        Owner = $parts[0]
        Name = $parts[1]
    }
}

function Get-ReleaseAssets {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Release asset directory does not exist: $Path"
    }

    $placeholderNames = @(".gitkeep", "README.md", "README.txt")

    $assets = Get-ChildItem -LiteralPath $Path -File |
        Where-Object { $placeholderNames -notcontains $_.Name } |
        Sort-Object Name

    if (-not $assets) {
        throw "No uploadable files found in $Path. Put the tocomini build artifacts in this directory first."
    }

    return $assets
}

function New-NameSet {
    param([object[]]$Names)

    $set = New-Object "System.Collections.Generic.HashSet[string]" -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Names) {
        if ($name) {
            [void]$set.Add([string]$name)
        }
    }

    return ,$set
}

function Get-ReleaseNotes {
    if ($NotesFile) {
        if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) {
            throw "Notes file does not exist: $NotesFile"
        }

        return Get-Content -Raw -Encoding UTF8 -LiteralPath $NotesFile
    }

    if ($Notes) {
        return $Notes
    }

    return "Release $Tag"
}

function Publish-GitHubRelease {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$TagName,
        [Parameter(Mandatory = $true)][string]$ReleaseTitle,
        [Parameter(Mandatory = $true)][object[]]$Assets
    )

    Write-Host ""
    Write-Host "== GitHub: $Repo / $TagName =="

    & gh auth status --hostname github.com *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run gh auth login first."
    }

    $releaseExists = $false
    & gh release view $TagName --repo $Repo *> $null
    if ($LASTEXITCODE -eq 0) {
        $releaseExists = $true
    }

    if (-not $releaseExists) {
        $createArgs = @("release", "create", $TagName, "--repo", $Repo, "--title", $ReleaseTitle, "--target", $TargetCommitish)

        if ($NotesFile) {
            $createArgs += @("--notes-file", $NotesFile)
        }
        elseif ($Notes) {
            $createArgs += @("--notes", $Notes)
        }
        else {
            $createArgs += @("--generate-notes")
        }

        if ($Prerelease) {
            $createArgs += "--prerelease"
        }

        Write-Host "Creating release..."
        & gh @createArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create GitHub release."
        }
    }
    else {
        Write-Host "Release exists. Checking assets..."
    }

    $existingAssetNames = @(& gh release view $TagName --repo $Repo --json assets --jq ".assets[].name" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read GitHub release assets."
    }

    $existingNames = New-NameSet -Names $existingAssetNames
    $missingAssets = @()

    foreach ($asset in $Assets) {
        if ($existingNames.Contains($asset.Name)) {
            Write-Host "Skip existing GitHub asset: $($asset.Name)"
        }
        else {
            $missingAssets += $asset
        }
    }

    if (-not $missingAssets) {
        Write-Host "No GitHub assets to upload."
        return
    }

    $uploadArgs = @("release", "upload", $TagName, "--repo", $Repo)
    foreach ($asset in $missingAssets) {
        $uploadArgs += $asset.FullName
    }

    Write-Host "Uploading GitHub assets:"
    foreach ($asset in $missingAssets) {
        Write-Host " - $($asset.Name)"
    }

    & gh @uploadArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload GitHub release assets."
    }

    Write-Host "GitHub release ready: https://github.com/$Repo/releases/tag/$TagName"
}

function Join-GiteeApiUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$WithAccessToken
    )

    $baseUrl = "https://gitee.com/api/v5"
    $url = "$baseUrl$Path"

    if ($WithAccessToken) {
        $separator = "?"
        if ($url.Contains("?")) {
            $separator = "&"
        }
        $url = "$url$separator" + "access_token=$([uri]::EscapeDataString($script:GiteeAccessToken))"
    }

    return $url
}

function Invoke-GiteeJson {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Body,
        [switch]$AllowNotFound
    )

    $headers = @{
        "User-Agent" = "linlin-pub-release-script"
    }

    $url = Join-GiteeApiUrl -Path $Path -WithAccessToken:($Method -eq "GET")

    if ($Method -ne "GET") {
        if (-not $Body) {
            $Body = @{}
        }
        $Body["access_token"] = $script:GiteeAccessToken
    }

    try {
        if ($Method -eq "GET") {
            return Invoke-RestMethod -Method Get -Uri $url -Headers $headers
        }

        return Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -Body $Body -ContentType "application/x-www-form-urlencoded"
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($AllowNotFound -and $statusCode -eq 404) {
            return $null
        }

        $message = $_.Exception.Message
        if ($_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader -ArgumentList $stream
                $responseText = $reader.ReadToEnd()
                if ($responseText) {
                    $message = "$message $responseText"
                }
            }
        }

        throw $message
    }
}

function Get-GiteeReleaseByTag {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$RepoName,
        [Parameter(Mandatory = $true)][string]$TagName
    )

    $ownerPart = [uri]::EscapeDataString($Owner)
    $repoPart = [uri]::EscapeDataString($RepoName)
    $tagPart = [uri]::EscapeDataString($TagName)
    return Invoke-GiteeJson -Method "GET" -Path "/repos/$ownerPart/$repoPart/releases/tags/$tagPart" -AllowNotFound
}

function New-GiteeRelease {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$RepoName,
        [Parameter(Mandatory = $true)][string]$TagName,
        [Parameter(Mandatory = $true)][string]$ReleaseTitle
    )

    $ownerPart = [uri]::EscapeDataString($Owner)
    $repoPart = [uri]::EscapeDataString($RepoName)

    $body = @{
        tag_name = $TagName
        name = $ReleaseTitle
        body = Get-ReleaseNotes
        target_commitish = $TargetCommitish
    }

    if ($Prerelease) {
        $body["prerelease"] = "true"
    }

    return Invoke-GiteeJson -Method "POST" -Path "/repos/$ownerPart/$repoPart/releases" -Body $body
}

function Get-GiteeReleaseAssets {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$RepoName,
        [Parameter(Mandatory = $true)]$ReleaseId
    )

    $ownerPart = [uri]::EscapeDataString($Owner)
    $repoPart = [uri]::EscapeDataString($RepoName)
    return Invoke-GiteeJson -Method "GET" -Path "/repos/$ownerPart/$repoPart/releases/$ReleaseId/attach_files?per_page=100"
}

function Get-GiteeAssetNames {
    param([object]$AssetResponse)

    $names = @()
    if (-not $AssetResponse) {
        return $names
    }

    foreach ($item in @($AssetResponse)) {
        if ($item.PSObject.Properties.Name -contains "name") {
            $names += $item.name
        }
    }

    return $names
}

function Upload-GiteeAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$RepoName,
        [Parameter(Mandatory = $true)]$ReleaseId,
        [Parameter(Mandatory = $true)]$Asset
    )

    Add-Type -AssemblyName System.Net.Http

    $ownerPart = [uri]::EscapeDataString($Owner)
    $repoPart = [uri]::EscapeDataString($RepoName)
    $url = Join-GiteeApiUrl -Path "/repos/$ownerPart/$repoPart/releases/$ReleaseId/attach_files" -WithAccessToken

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $content = New-Object System.Net.Http.MultipartFormDataContent
    $fileStream = $null
    $fileContent = $null

    try {
        $fileStream = [System.IO.File]::OpenRead($Asset.FullName)
        $fileContent = New-Object System.Net.Http.StreamContent -ArgumentList $fileStream
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
        $content.Add($fileContent, "file", $Asset.Name)

        $response = $client.PostAsync($url, $content).GetAwaiter().GetResult()
        $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            throw "Gitee upload failed for $($Asset.Name): $([int]$response.StatusCode) $responseText"
        }

        if ($responseText) {
            return $responseText | ConvertFrom-Json
        }

        return $null
    }
    finally {
        if ($fileContent) {
            $fileContent.Dispose()
        }
        if ($fileStream) {
            $fileStream.Dispose()
        }
        $content.Dispose()
        $client.Dispose()
    }
}

function Publish-GiteeRelease {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$TagName,
        [Parameter(Mandatory = $true)][string]$ReleaseTitle,
        [Parameter(Mandatory = $true)][object[]]$Assets
    )

    Write-Host ""
    Write-Host "== Gitee: $Repo / $TagName =="

    $repoParts = Split-Repo -Repo $Repo
    $owner = $repoParts.Owner
    $repoName = $repoParts.Name

    $release = Get-GiteeReleaseByTag -Owner $owner -RepoName $repoName -TagName $TagName
    if (-not $release) {
        Write-Host "Creating release..."
        $release = New-GiteeRelease -Owner $owner -RepoName $repoName -TagName $TagName -ReleaseTitle $ReleaseTitle
    }
    else {
        Write-Host "Release exists. Checking assets..."
    }

    if (-not ($release.PSObject.Properties.Name -contains "id") -or -not $release.id) {
        throw "Gitee release response did not include an id."
    }

    $releaseId = $release.id
    $existingAssetResponse = Get-GiteeReleaseAssets -Owner $owner -RepoName $repoName -ReleaseId $releaseId
    $existingNames = New-NameSet -Names (Get-GiteeAssetNames -AssetResponse $existingAssetResponse)

    $missingAssets = @()
    foreach ($asset in $Assets) {
        if ($existingNames.Contains($asset.Name)) {
            Write-Host "Skip existing Gitee asset: $($asset.Name)"
        }
        else {
            $missingAssets += $asset
        }
    }

    if (-not $missingAssets) {
        Write-Host "No Gitee assets to upload."
        return
    }

    Write-Host "Uploading Gitee assets:"
    foreach ($asset in $missingAssets) {
        Write-Host " - $($asset.Name)"
        [void](Upload-GiteeAsset -Owner $owner -RepoName $repoName -ReleaseId $releaseId -Asset $asset)
    }

    Write-Host "Gitee release ready: https://gitee.com/$Repo/releases/tag/$TagName"
}

Require-Command -Name "git" -InstallHint "Install Git and make sure git is available in PATH."
Require-Command -Name "gh" -InstallHint "Install GitHub CLI and run gh auth login."

if (-not $Title) {
    $Title = $Tag
}

if (-not $DistPath) {
    $DistPath = Join-Path $PSScriptRoot "dist"
}

if (-not $GiteeToken) {
    $GiteeToken = $env:GITEE_TOKEN
}

if (-not $GiteeToken) {
    throw "GITEE_TOKEN is not set. Create a Gitee personal access token, then set `$env:GITEE_TOKEN."
}

$script:GiteeAccessToken = $GiteeToken

$resolvedGitHubRepo = Resolve-RemoteRepo -RepoValue $GitHubRepo -RemoteName "origin" -HostName "github.com"
$resolvedGiteeRepo = Resolve-RemoteRepo -RepoValue $GiteeRepo -RemoteName "gitee" -HostName "gitee.com"
$resolvedDistPath = (Resolve-Path -LiteralPath $DistPath).Path
$assets = @(Get-ReleaseAssets -Path $resolvedDistPath)

Write-Host "Release tag: $Tag"
Write-Host "Asset directory: $resolvedDistPath"
Write-Host "Asset count: $($assets.Count)"

Publish-GitHubRelease -Repo $resolvedGitHubRepo -TagName $Tag -ReleaseTitle $Title -Assets $assets
Publish-GiteeRelease -Repo $resolvedGiteeRepo -TagName $Tag -ReleaseTitle $Title -Assets $assets

Write-Host ""
Write-Host "Publish finished."
