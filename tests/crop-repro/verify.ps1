[CmdletBinding()]
param(
    [string]$GpuExecutable = '.\build\src_gpu\Release\dssim-Vulkan.exe',
    [string]$OutputDirectory = '.\out\crop-fix'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$gpu = (Resolve-Path -LiteralPath $GpuExecutable).Path
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$invariant = [Globalization.CultureInfo]::InvariantCulture

function Run-Ffmpeg {
    & ffmpeg -hide_banner -loglevel error -y @args
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg failed: $LASTEXITCODE" }
}

function Assert-Video {
    param($Name, $Left, $Right, [int]$Depth)
    $csv = Join-Path $output "$Name-depth$Depth.csv"
    $log = Join-Path $output "$Name-depth$Depth.log"
    & $gpu $Left $Right --pipeline-depth $Depth --profiling --csv $csv *> $log
    if ($LASTEXITCODE -ne 0) { throw "${Name}: GPU failed; see $log" }
    $summary = @(Get-Content $log | Select-String '^0\.00000000\s+.*frames=5$')
    if ($summary.Count -ne 1) { throw "${Name}: expected five frames with zero mean DSSIM; see $log" }
    if ((Get-Content $csv -TotalCount 1) -cne 'time_seconds,frame_number,dssim') {
        throw "${Name}: invalid CSV header"
    }
    $rows = @(Import-Csv $csv)
    if ($rows.Count -ne 5) { throw "${Name}: CSV row count differs from summary" }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $score = [double]::Parse($rows[$i].dssim, $invariant)
        if ([int]$rows[$i].frame_number -ne $i -or
            [double]::IsNaN($score) -or [double]::IsInfinity($score) -or
            $score.ToString('F8', $invariant) -cne '0.00000000') {
            throw "${Name}: invalid frame number or nonzero/nonfinite score at row $i"
        }
    }
    Write-Host "PASS $Name depth=$Depth frames=5 score=0.00000000"
}

$pairs = @(
    @{ Name = 'left-top'; Left = Join-Path $PSScriptRoot 'cropped.mp4'; Right = Join-Path $PSScriptRoot 'visible.mp4' },
    @{ Name = 'right-bottom'; Left = Join-Path $PSScriptRoot 'right-bottom.mp4'; Right = Join-Path $PSScriptRoot 'right-bottom-visible.mp4' }
)

# Add small, reproducible NV12/P010 cases without overwriting the saved fixtures.
# All four edges are cropped, with an origin that is not a workgroup boundary.
foreach ($bits in @(8, 10)) {
    $format = if ($bits -eq 8) { 'yuv420p' } else { 'yuv420p10le' }
    $full = Join-Path $output "full-$bits.mp4"
    $cropped = Join-Path $output "four-edges-$bits.mp4"
    $visible = Join-Path $output "four-edges-visible-$bits.mp4"
    Run-Ffmpeg -i (Join-Path $PSScriptRoot 'full.mp4') -an '-c:v' libx265 -preset ultrafast -x265-params 'lossless=1:log-level=error:pools=1' -pix_fmt $format -colorspace bt709 -color_range tv $full
    Run-Ffmpeg -i $full -map 0:v:0 '-c:v' copy '-bsf:v' 'hevc_metadata=crop_left=2:crop_top=4:crop_right=14:crop_bottom=12' $cropped
    # Explicitly crop the uncropped software decode, independently of the SPS
    # crop path. Preserve the exact 4:2:0 chroma samples when encoding losslessly.
    Run-Ffmpeg -hwaccel none -i $full -vf 'crop=640:368:2:4:exact=1' -an '-c:v' libx265 -preset ultrafast -x265-params 'lossless=1:log-level=error:pools=1' -pix_fmt $format -colorspace bt709 -color_range tv $visible
    $croppedMd5 = Join-Path $output "four-edges-$bits.framemd5"
    $visibleMd5 = Join-Path $output "four-edges-visible-$bits.framemd5"
    # FFmpeg's software crop must not round the two-pixel left crop for alignment.
    Run-Ffmpeg -hwaccel none -flags +unaligned -i $cropped -map 0:v:0 -pix_fmt $format -f framemd5 $croppedMd5
    Run-Ffmpeg -hwaccel none -i $visible -map 0:v:0 -pix_fmt $format -f framemd5 $visibleMd5
    if (Compare-Object (Get-Content $croppedMd5) (Get-Content $visibleMd5)) {
        throw "Software-decoded $bits-bit visible frames differ"
    }
    $pairs += @{ Name = "four-edges-$bits"; Left = $cropped; Right = $visible }
}

# Explicit 1920x1088 HEVC surface / 1920x1080 display regression. Sampling
# against the visible height would stretch the padded input and fail equality.
$paddedFull = Join-Path $output 'padded-1088-full.mp4'
$padded = Join-Path $output 'padded-1088.mp4'
$paddedVisible = Join-Path $output 'padded-1080-visible.webm'
Run-Ffmpeg -f lavfi -i 'testsrc2=size=1920x1088:rate=5:duration=1' -an '-c:v' libx265 -preset ultrafast -x265-params 'lossless=1:log-level=error:pools=1' -pix_fmt yuv420p -colorspace bt709 -color_range tv $paddedFull
Run-Ffmpeg -i $paddedFull -map 0:v:0 '-c:v' copy '-bsf:v' 'hevc_metadata=crop_left=0:crop_top=0:crop_right=0:crop_bottom=8' $padded
# Use lossless VP9 for the counterpart: HEVC may allocate 1088 rows even for
# a coded height of 1080, which would stretch both inputs alike and hide a bug.
Run-Ffmpeg -hwaccel none -i $paddedFull -vf 'crop=1920:1080:0:0:exact=1' -an '-c:v' libvpx-vp9 -lossless 1 -cpu-used 8 -threads 2 -pix_fmt yuv420p -colorspace bt709 -color_range tv $paddedVisible
$paddedMd5 = Join-Path $output 'padded-1088.framemd5'
$paddedVisibleMd5 = Join-Path $output 'padded-1080-visible.framemd5'
Run-Ffmpeg -hwaccel none -i $padded -map 0:v:0 -pix_fmt yuv420p -f framemd5 $paddedMd5
Run-Ffmpeg -hwaccel none -i $paddedVisible -map 0:v:0 -pix_fmt yuv420p -f framemd5 $paddedVisibleMd5
if (Compare-Object (Get-Content $paddedMd5) (Get-Content $paddedVisibleMd5)) {
    throw 'Software-decoded 1088-surface/1080-display frames differ'
}
$pairs += @{ Name = 'padded-1088'; Left = $padded; Right = $paddedVisible }

foreach ($pair in $pairs) {
    # The normal DSSIM reduction can retain a sub-8-decimal rounding residue.
    # Compare the more precise CSV scores mechanically to the same-input path.
    Assert-Video "$($pair.Name)-identity" $pair.Right $pair.Right 3
    foreach ($depth in @(1, 3)) {
        Assert-Video $pair.Name $pair.Left $pair.Right $depth
        Assert-Video "$($pair.Name)-reverse" $pair.Right $pair.Left $depth
        $identityScores = @(Import-Csv (Join-Path $output "$($pair.Name)-identity-depth3.csv") | ForEach-Object dssim)
        foreach ($name in @($pair.Name, "$($pair.Name)-reverse")) {
            $scores = @(Import-Csv (Join-Path $output "$name-depth$depth.csv") | ForEach-Object dssim)
            if (Compare-Object $identityScores $scores -SyncWindow 0) {
                throw "${name}: per-frame scores differ from the identical-input baseline"
            }
        }
    }
    if (Compare-Object (Get-Content (Join-Path $output "$($pair.Name)-depth1.csv")) (Get-Content (Join-Path $output "$($pair.Name)-depth3.csv"))) {
        throw "$($pair.Name): depth 1 and 3 CSVs differ"
    }
}

# A crop is not permission to resize or truncate mismatched videos.
$mismatchLog = Join-Path $output 'dimension-mismatch.log'
& $gpu (Join-Path $PSScriptRoot 'full.mp4') (Join-Path $PSScriptRoot 'cropped.mp4') *> $mismatchLog
if ($LASTEXITCODE -eq 0 -or -not (Select-String -Path $mismatchLog -SimpleMatch 'video frames have different dimensions')) {
    throw 'Different visible dimensions were not rejected'
}
Write-Host 'PASS different visible dimensions rejected'
Write-Host 'All HEVC crop checks passed.'
