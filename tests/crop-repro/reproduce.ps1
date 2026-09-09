$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
function Run-Ffmpeg {
    & ffmpeg -hide_banner -loglevel error -y @args
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg failed: $LASTEXITCODE" }
}
# Encode one lossless picture sequence, then signal a top/left conformance crop.
Run-Ffmpeg -f lavfi -i 'testsrc2=size=656x384:rate=5:duration=1' -an '-c:v' libx265 -preset ultrafast -x265-params 'lossless=1:log-level=error:pools=1' -pix_fmt yuv420p -colorspace bt709 -color_range tv full.mp4
Run-Ffmpeg -i full.mp4 -map 0:v:0 '-c:v' copy '-bsf:v' 'hevc_metadata=crop_left=16:crop_top=16:crop_right=0:crop_bottom=0' cropped.mp4
# Materialize exactly the visible pixels using software decoding, then encode losslessly.
Run-Ffmpeg -hwaccel none -i cropped.mp4 -an '-c:v' libx265 -preset ultrafast -x265-params 'lossless=1:log-level=error:pools=1' -pix_fmt yuv420p -colorspace bt709 -color_range tv visible.mp4
Run-Ffmpeg -hwaccel none -i cropped.mp4 -map 0:v:0 -pix_fmt yuv420p -f framemd5 cropped.framemd5
Run-Ffmpeg -hwaccel none -i visible.mp4 -map 0:v:0 -pix_fmt yuv420p -f framemd5 visible.framemd5
$difference = Compare-Object (Get-Content cropped.framemd5) (Get-Content visible.framemd5)
if ($difference) { throw 'Software-decoded frames differ.' }
# Control: the same amount of padding, but removed from right/bottom instead.
Run-Ffmpeg -i full.mp4 -map 0:v:0 '-c:v' copy '-bsf:v' 'hevc_metadata=crop_left=0:crop_top=0:crop_right=16:crop_bottom=16' right-bottom.mp4
Run-Ffmpeg -hwaccel none -i right-bottom.mp4 -an '-c:v' libx265 -preset ultrafast -x265-params 'lossless=1:log-level=error:pools=1' -pix_fmt yuv420p -colorspace bt709 -color_range tv right-bottom-visible.mp4
foreach ($variant in @('plain', 'patched')) {
    & "../../out/av1-patch-check/$variant/dssim-Vulkan.exe" cropped.mp4 visible.mp4 --profiling --csv "$variant.csv" *> "$variant.log"
    "${variant}: exit=$LASTEXITCODE"
    Get-Content "$variant.log" -Tail 10
    & "../../out/av1-patch-check/$variant/dssim-Vulkan.exe" right-bottom.mp4 right-bottom-visible.mp4 --csv "$variant-control.csv" *> "$variant-control.log"
    "${variant} control: exit=$LASTEXITCODE"
    Get-Content "$variant-control.log" -Tail 2
}
