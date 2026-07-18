# Package a project into a .qlpak for Q-emuLator. Run from the project
# directory (the Makefiles do): expects <Name>_bin, boot and <Name>.QCF
# there, and produces <Name>.qlpak.
#
# A .qlpak is a zip: a .QCF session config at the root plus a folder of QL
# files that Q-emuLator mounts as FLP1. Zip/Windows filesystems cannot store
# a QDOS file header, so Q-emuLator expects executables to carry a 30-byte
# "]!QDOS File Header" prefix holding the file type and dataspace.
# Format details: docs/qemulator.md.
param(
    [Parameter(Mandatory)][string]$Name,
    [int]$DataSpace = 512
)
$ErrorActionPreference = 'Stop'

$stage = Join-Path $PWD 'stage'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Path (Join-Path $stage $Name) | Out-Null

$code = [IO.File]::ReadAllBytes((Join-Path $PWD "${Name}_bin"))
$hdr = New-Object byte[] 30
[Text.Encoding]::ASCII.GetBytes(']!QDOS File Header').CopyTo($hdr, 0)
$hdr[19] = 15                                # header length in 16-bit words
$hdr[21] = 1                                 # QDOS file type 1 = executable
$hdr[22] = ($DataSpace -shr 24) -band 0xff   # dataspace, big-endian long
$hdr[23] = ($DataSpace -shr 16) -band 0xff
$hdr[24] = ($DataSpace -shr 8) -band 0xff
$hdr[25] = $DataSpace -band 0xff
[IO.File]::WriteAllBytes((Join-Path $stage "$Name\${Name}_bin"), $hdr + $code)

# boot must be LF-only (QDOS newline); the QCF is a Windows config file (CRLF)
$boot = ((Get-Content boot) -join "`n") + "`n"
[IO.File]::WriteAllText((Join-Path $stage "$Name\boot"), $boot, [Text.Encoding]::ASCII)
$qcf = ((Get-Content "$Name.QCF") -join "`r`n") + "`r`n"
[IO.File]::WriteAllText((Join-Path $stage "$Name.QCF"), $qcf, [Text.Encoding]::ASCII)

$zip = Join-Path $PWD "$Name.zip"
$pak = Join-Path $PWD "$Name.qlpak"
Remove-Item $zip, $pak -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Rename-Item $zip $pak
Write-Host "Built $Name.qlpak (dataspace $DataSpace bytes)"
