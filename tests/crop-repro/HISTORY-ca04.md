# HEVC sampling before ca04a35

Verified on 2026-09-08. **The shader before `ca04a35` did have a sampling
dimension bug when the decoded image allocation exceeded the output size.**
The AV1 FFmpeg compatibility patch does not fix this separate HEVC problem.
The previous statement that the shader already used `textureSize` referred to
HEAD `86b3703` at the start of the current crop task, not to `ca04a35`.

## Source history

| Revision | YUV sampling behavior |
| --- | --- |
| `e2b5670` (initial video support, 2026-07-12) | Normalize by output `params.width/height`; sample UV with linear filtering |
| `8cc9533eb1eae1043f4867668f411e148a29db01` (`ca04a35^`) | Same shader |
| `ca04a3535e4e1e85d07df20a4889c17b0d2f3560` (2026-08-02) | Adds test media only; no source change |
| `a3329fb38e02ee5e8cbac87ab63ac30f425a8840` (2026-08-03) | Uses Y-plane `textureSize` and snaps UV reads to chroma texel centers |
| `86b3703ddfa976527f67425799fe5c2787d87a75` (current task baseline) | Already contains the `a3329fb` shader |
| Current uncommitted crop fix | Additionally propagates each input's visible rectangle and crop origin |

The shader blob from `e2b5670` through `a3329fb^`, including both `ca04a35^`
and `ca04a35`, is `1d9b6999450646c3eec3b49ad81b97f2a9cb80f9`.
The `a3329fb` / HEAD shader blob is
`59107e992e2bfd2096f5c0d59c71226555bea78b`.

At `ca04a35^`, `src_gpu/video_decoder.cpp` lines 240-241 take width/height
from `AVFrame`. `src_gpu/dssim-WebGPU.cpp` lines 1935-1936 pass the output
width/height in `YuvParams`. `CreateVideoPlaneView` creates full-plane image
views. The old shader uses:

```glsl
vec2 position = (vec2(gid.xy) + vec2(0.5)) /
                vec2(params.width, params.height);
float y = texture(y_plane, position).r;
vec2 uv = texture(uv_plane, position).rg;
```

For a 1920x1088 allocation displaying 1920x1080, this maps 1080 output rows
across the full 1088-row image, including padding. The denominator must describe
the actual image view, while dispatch bounds describe the visible output.
Matching output and allocation sizes avoids this particular scale error;
left/top crop origins and chroma filtering are separate considerations.

## Isolated runtime comparison

The exact parent source was extracted with `git archive`, configured as C++20,
and built under `out/ca04-sampling-audit/parent-build`. Its historical executable
name is `dssim-WebGPU.exe`, though its video backend is Vulkan. The source tree,
normal build, and FFmpeg prefix were not replaced.

Two copies of this executable, its DLLs, and shaders were made. Only the YUV
shader differs: `extent-only` changes the denominator alone, and `a3329fb`
uses the exact shader from that commit, including its UV-center change.

All successful runs below used unmodified FFmpeg 8.1.2 DLLs, Radeon RX 9070,
and AMD proprietary Vulkan driver 2.0.373 (`driverInfo=25.20.42.14`). This tests
historical application source on the current runtime; it does not reconstruct
the driver and FFmpeg versions installed when those commits were authored.

| Shader | Bottom-padding control, 5 frames | Current regression pair 12, 60 frames |
| --- | ---: | ---: |
| Exact `ca04a35^` | 0.04043603 | 0.01009154 |
| Old shader, denominator changed to `textureSize` only | 0.00000000 | 0.01009154 |
| Exact `a3329fb` shader | 0.00000000 | 0.01040559 |
| Local D3D11VA reference | 0.00000000 | 0.01041260 |

Every successful application run exited 0. The six application CSVs have the
required header, contiguous frame numbers from zero, finite scores, and the
expected 5 or 60 rows. Reference scores were computed by the local executable,
not hand-authored expectations.

The padding control is `padded-1088.mp4` versus
`padded-1080-visible.webm` under `out/av1-app-compat/crop/`. It uses HEVC with
only bottom crop 8 (no left/top crop), and a lossless VP9 counterpart. All five
software-decoded framemd5 records match. Current application geometry logs show
1920x1080 AVFrames for both inputs, with hardware frames of 1920x1088 and
1920x1080 respectively. `tests/crop-repro/verify.ps1` generates these fixtures.
The denominator-only result isolates the sampling scale error from UV filtering
and from AV1 decoding: neither input uses AV1.

Current regression pair 12 is `tests/raw1k_lossless-cut.mp4` versus
`tests/nv5_hevc_vbr_6000_lossless-encode-cut.mp4`. Changing only normalization
does not affect its score. The additional chroma-center correction changes it,
reducing relative error against the current reference from 3.0834% to 0.0673%.
Thus absence of a padding-scale effect in this pair is not proof that the old
shader matched the reference's chroma sampling.

## FFmpeg patch independence

The exact old executable and old shader were also run with the existing archived
patched DLLs from `out/av1-patch-check/patched`, copied into a separate
`out/ca04-sampling-audit/old-with-archived-patched-dlls` directory.
The padding control still produced **0.04043603, 5 frames, exit 0**.
No new FFmpeg source patch was applied during this investigation.

| Runtime | avcodec-62.dll SHA-256 |
| --- | --- |
| Current unmodified GPU prefix, normal executable, historical baseline | `1A2050CAA93B2F7F0FAF46814381E4FE67F2C2932B4291817BE7E22F162C7045` |
| Isolated archived patched runtime | `916E6AA92395F16E563C914CF2D886F4CBC265E5A405AB6F243D475438A735FF` |

The AV1 patch addresses decode tile metadata. It does not change the HEVC image
view or the comparison shader's denominator. The measured result confirms the
HEVC sampling problem remains with those patched DLLs as well.

## Limitations and retained evidence

The two `hevc-amf_quality_qp-*.mp4` files added by `ca04a35` fail Vulkan hardware
decoder initialization on this machine, before sampling, with every shader
variant. The qp25 file also fails with the current application and the D3D11VA
reference. Those runs are recorded as initialization failures, not valid scores.
They cannot establish whether those particular files rendered correctly on the
historical runtime. Their reported coded height is 1088 and display height is
1080, but that metadata alone is not a successful GPU reproduction.

An optional API-dump layer run terminated with `0xC0000005`. Its partial log
contains successful image-creation calls with 1920x1088 HEVC and 1920x1080 VP9
extents, but was not used as a successful comparison or CSV validation. The
scores above all come from separate successful runs without that layer.

Retained local artifacts under `out/ca04-sampling-audit/`:

- `parent-source.zip`, `parent-source/`, `parent-build/`, `configure.log`, `build.log`.
- `run-variants.ps1`, `variant-results.csv`, `reference-results.csv`.
- `original-*`, `extent-only-*`, and `a3329fb-*` per-case logs and CSVs.
- `old-patched-padding.log`, `current-amf25.log`, `reference-amf25.log`.
- `old-padding-api-dump.log` (partial instrumentation run only).

To repeat the retained shader comparison from the repository root:

```powershell
& .\out\ca04-sampling-audit\run-variants.ps1
```

This investigation added documentation and isolated artifacts only. It preserved
the existing application changes, tests, FFmpeg sources, and normal runtime DLLs.
The earlier full 16/16 regression record remains in
[the application compatibility report](../vulkan-video-compat/README.md).
