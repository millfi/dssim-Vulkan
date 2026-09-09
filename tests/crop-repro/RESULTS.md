# HEVC crop fix verification — 2026-09-08

**Final status: 16/16 PASS with unmodified FFmpeg.** The later application-side
AV1 Vulkan dispatch adapter resolves the two failures recorded in the initial
HEVC-only verification below. See [the final verification record](../vulkan-video-compat/README.md).

The application now compares the visible rectangle, using unmodified FFmpeg.
For `cropped.mp4` this is **640x368 at coded-picture origin (16,16)**.
The original fixtures, generation script, pair list entries, and prior changes
remained in place. No encoded-input equality detection or score override was added.

## Display rectangle and Windows discrepancy

`ffmpeg -bsf:v trace_headers` reports these SPS values for `cropped.mp4`:

- `pic_width_in_luma_samples=656`, `pic_height_in_luma_samples=384`.
- `chroma_format_idc=1` (4:2:0).
- Conformance offsets in chroma units: left=8, top=8, right=0, bottom=0.
- `default_display_window_flag=0`.

The luma crop is therefore left=16, top=16, right=0, bottom=0, giving
the half-open rectangle `[16,656) x [16,384)`. This follows the conformance
window definition in [ITU-T H.265, section 7.4.3.2.1](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.265-202601-I%21%21PDF-E&lang=e&type=items).

MP4 box inspection found `tkhd` and `hev1` sample-entry dimensions of 656x384,
an identity track matrix, square pixels (`pasp=1:1`), and no `clap` box.
There is no second container crop or resize explaining 624x352.

The Windows native Media Foundation source-reader media type gives:

| File | MF frame size | MF minimum display aperture origin | MF aperture size | Shell property size |
| --- | --- | --- | --- | --- |
| cropped.mp4 | 656x384 | 16,16 | 640x368 | 624x352 |
| right-bottom.mp4 | 656x384 | 0,0 | 640x368 | 640x368 |
| visible.mp4 | 640x368 | 0,0 | 640x368 | 640x368 |

Microsoft defines `MFVideoArea.Area` as a **size**, independently of its origin;
it is not a bottom-right coordinate. The minimum display aperture is the valid
image region. See [MFVideoArea](https://learn.microsoft.com/en-us/windows/win32/api/mfobjects/ns-mfobjects-mfvideoarea)
and [MF_MT_MINIMUM_DISPLAY_APERTURE](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-mt-minimum-display-aperture-attribute).

The Shell's 624x352 equals `(640-16)x(368-16)`: it is consistent with subtracting
the origin again. The closed-source property handler's internal calculation was
not inspected, so that exact implementation explanation is an inference.
The SPS, container, FFmpeg software decode, and Windows native media type all
agree on the 640x368 rectangle above. Actual Windows player rendering was not
used as evidence; a trial NV12 decoder media-type request on this machine returned
`0xc00d5212` (the native compressed media type was still available).

The native Media Foundation probe is retained for reproduction:

```powershell
& cmake -S .\tests\crop-repro\windows-aperture -B .\out\crop-fix\windows-aperture-build
& cmake --build .\out\crop-fix\windows-aperture-build --config Release
& .\out\crop-fix\windows-aperture-build\Release\crop_windows_aperture.exe .\tests\crop-repro\cropped.mp4 .\tests\crop-repro\right-bottom.mp4 .\tests\crop-repro\visible.mp4
```

## Application changes and observed geometry

`VulkanVideoReader::Next` validates frame/surface dimensions and remaining crops,
then retains visible width/height and the luma origin for each input. Crop sums
are checked by subtraction to avoid overflow. FFmpeg's already-applied
right/bottom crops are not subtracted twice.

The shader receives separate 24-byte push constants for each input. Output
allocation, pairing, and dispatch use visible dimensions. Y coordinates include
the input's origin; UV coordinates use the absolute luma coordinate divided by
two. Each is normalized against that plane's actual `textureSize`.
Decoded GPU pixels are never transferred to CPU by the Vulkan application.
Queue depth, frame ownership, decode order, and shutdown code were unchanged.

The first-frame `--profiling` geometry logs show:

| Input | AVFrame | Remaining crop L,T,R,B | AVHWFramesContext | Visible | Origin |
| --- | --- | --- | --- | --- | --- |
| left/top NV12 | 656x384 | 16,16,0,0 | 656x384 | 640x368 | 16,16 |
| right/bottom NV12 | 640x368 | 0,0,0,0 | 656x384 | 640x368 | 0,0 |
| four-edge P010 | 642x372 | 2,4,0,0 | 656x384 | 640x368 | 2,4 |
| visible counterpart | 640x368 | 0,0,0,0 | 640x368 | 640x368 | 0,0 |

The allocation dimensions are taken from AVHWFramesContext, which the local
FFmpeg `hwcontext_vulkan.c` uses to create the images. For these multiplanar
NV12/P010 surfaces, luma/chroma extents are 656x384 / 328x192 and
640x368 / 320x184 respectively. The shader queries its image-view extents
directly; it does not assume that visible dimensions equal allocation dimensions.

The reference application's existing D3D11 readback also discarded remaining
crop metadata, causing pair 15 to fail with `656x384 vs 640x368`. Its application
adapter now copies only the remaining crop fields and calls the unmodified
`av_frame_apply_cropping(..., AV_FRAME_CROP_UNALIGNED)` before RGB conversion.
The reference score algorithm and FFmpeg source are unchanged.

## Initial HEVC-only verification (before the AV1 dispatch adapter)

- Normal CMake configure and Release `dssim_vulkan` build succeeded, using the
  repository's default C++20 settings. MSBuild required execution outside the
  filesystem sandbox because its FileTracker initialization was denied there.
- Fixed `tests/test_pairs.txt` GPU benchmark: all 16 pairs completed, exit 0.
- `verify.ps1`: all 20 successful crop/identity runs passed, each with 5 frames
  and printed DSSIM `0.00000000`; visible dimension mismatch was rejected.
  Cases cover the original left/top and right/bottom fixtures and reproducibly
  generated four-edge crops in NV12 and P010, both input orders, and depths 1/3.
  Software framemd5 results match; CSV header, row count, numbering, finite
  scores, and depth agreement are checked mechanically. Nine-decimal CSV scores
  match each corresponding same-input baseline exactly (some normal DSSIM
  reductions retain a 0.000000002 rounding residue). No score is overridden.
- The repaired reference returns zero for the original crop case and generated
  P010 crop case, with 5 frames each.
- Required `x264_medium_g40_fastdecode_crf40.mp4 / 3s.webm` video: exit 0,
  180 frames, finite mean DSSIM `0.06855461`. CSV header is
  `time_seconds,frame_number,dssim`, with exactly 180 finite rows numbered 0–179.
  The depth-1 and default depth-3 CSVs match exactly.
- `check_regression.ps1` completed the full mechanical comparison against
  `src_reference/target/release/dssim.exe`: **14 PASS, 2 FAIL, exit 1**.
  All 10 PNG pairs pass (maximum relative error 0.5685%), existing HEVC/H.264
  pairs pass, both crop pairs pass, and image/video identity checks pass.
  The two failing AV1 pairs remain in the list without exemptions:

| Pair | Reference | GPU | Result |
| --- | --- | --- | --- |
| 11: AV1 / its lossless HEVC re-encode | 0.00000000 | 0.39387601 | FAIL |
| 14: lossless source / AV1 | 0.02084196 | 0.41372452 | FAIL |

These are the separate unpatched AMD AV1 decoding issue described in the
handoff. Corrupted AV1 scores vary between runs; this crop correction does not
claim to repair AV1 decoding. The overall regression is **not all green**.

For isolation, the executable and shaders from the baseline for this crop-fix
task (HEAD `86b3703`, already after the `a3329fb` sampling fix) were copied to
`out/crop-fix/baseline-current-dlls` with the **same DLLs as the current executable**.
It still fails the left/top crop with a dimension mismatch (exit 1). Its 12
pre-existing non-AV1 pair scores match the final application's scores exactly.
Its AV1 pairs also fail badly (0.39498385 and 0.41514220 in that run), confirming
that the AV1 failure precedes this application change. Only this historical
baseline run used the first 14 pairs; the final benchmark and reference
regression both used the complete, unmodified 16-pair list.

This baseline is not the older `ca04a35` revision. That revision still used
output dimensions for normalized sampling and fails a bottom-padding case;
see [the historical investigation](HISTORY-ca04.md).

Local logs and CSVs are under `out/crop-fix/`; key files are
`fixed-benchmark-final.log`, `regression-final.log`, `crop-verification.log`,
`windows-apertures.log`, and `video.log`. The required video CSV is
`out/video_scores.csv`. The upstream and private GPU `vulkan_av1.c` hashes match,
and the normal executable's `avcodec-62.dll` matches `ffmpeg-gpu-shared/bin`.
