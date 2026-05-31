$ErrorActionPreference = "Stop"

$ZigVersion="0.13.0"
$Target="windows"
$Arch="x86_64"

$BuildsUrl = "https://ziglang.org/builds/zig-${Target}-${Arch}-${ZigVersion}.zip"
$ReleaseUrl = "https://ziglang.org/download/$ZigVersion/zig-${Target}-${Arch}-${ZigVersion}.zip"
$Urls = @($BuildsUrl)

if ($ZigVersion -notmatch "-dev") {
  $Urls = @($ReleaseUrl, $BuildsUrl)
}
$CacheDir = (mkdir -Force (Join-Path $PSScriptRoot "../.cache"))
$TarPath = Join-Path $CacheDir "zig-${ZigVersion}.zip"
$OutDir = Join-Path $CacheDir "zig"

if (Test-Path $OutDir\.tag) {
  $CurrentTag = Get-Content -Path (Join-Path $OutDir ".tag")
  if ($CurrentTag -eq $ZigVersion) {
    return
  }
}

Remove-Item $OutDir -ErrorAction SilentlyContinue -Recurse
$null = mkdir -Force $OutDir
Push-Location $CacheDir
try {
  if (!(Test-Path $TarPath)) {
    $Downloaded = $false
    foreach ($Url in $Urls) {
      try {
        Write-Host "-- Downloading Zig from: $Url"
        Invoke-RestMethod $Url -OutFile $TarPath
        $Downloaded = $true
        break
      } catch {
        Remove-Item -Force -ErrorAction SilentlyContinue $TarPath
      }
    }

    if (-not $Downloaded) {
      Write-Error "Failed to fetch Zig from all known URLs"
      throw "Zig download failed"
    }
  }

  Remove-Item "$OutDir" -Recurse
  Expand-Archive "$TarPath" "$OutDir\..\"
  Move-Item "zig-$Target-$Arch-$ZigVersion" "zig"
  Set-Content -Path (Join-Path $OutDir ".tag") -Value "$ZigVersion"
} catch {
  Remove-Item -Force -ErrorAction SilentlyContinue $OutDir
  throw $_
} finally {
  Pop-Location
}