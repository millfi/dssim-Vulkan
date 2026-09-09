# HEVC conformance-crop reproduction

Both pairs are listed in `tests/test_pairs.txt`. Each contains five frames at
640x368 visible resolution. Correct decoding should produce DSSIM zero.

- `cropped.mp4` has a 656x384 coded picture with 16-pixel left/top crops.
  `visible.mp4` losslessly re-encodes its software-decoded visible pixels.
  The saved `framemd5` files match for all frames.
- `right-bottom.mp4` applies the same crop amounts to the right/bottom instead.
  `right-bottom-visible.mp4` is its lossless visible-pixel counterpart.
- `full.mp4` is the lossless synthetic source before either crop.

Before the application crop fix, the left/top pair exited with
`video frames have different dimensions`, with and without the AMD AV1 patch.
Both pairs now succeed using unmodified FFmpeg, with five frames and DSSIM
`0.00000000`. Neither entry is an expected-error exemption in the regression runner.

To verify the current application from the repository root:

```powershell
& .\tests\crop-repro\verify.ps1
```

This verifies both input orders and pipeline depths 1/3, checks every CSV row,
and mechanically compares per-frame scores with the normal identical-input path.
It also generates 8/10-bit four-edge crop cases and an explicit 1920x1088 HEVC
surface / 1920x1080 VP9 comparison under `out/crop-fix`, verifies
software-decoded frame hashes, and requires mismatched visible dimensions to fail.
It needs FFmpeg with libx265/libvpx-vp9/hevc_metadata on PATH, but no patched build.
The original fixtures are preserved. See [RESULTS.md](RESULTS.md) for display
geometry, Windows metadata findings, and regression results.

For the historical plain/patched comparison, regenerate from the repository root:

```powershell
& .\tests\crop-repro\reproduce.ps1
```

Requires FFmpeg with libx265 and hevc_metadata on PATH, plus the isolated plain
and patched executables and DLLs in `out/av1-patch-check/{plain,patched}`.
The script overwrites generated fixtures and writes comparison logs locally.
