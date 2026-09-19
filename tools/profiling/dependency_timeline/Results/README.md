# Dependency timeline result

`gradation-256.timeline.txt` follows
`../Specification/dependency-timeline.ebnf`. Its bucket durations were captured
with:

```powershell
& .\build\src_gpu\Release\dssim-Vulkan.exe `
    .\tests\gradation.png `
    .\tests\gradation-256.png `
    --out .\build\dependency_timeline_profile.json `
    --profiling
```

`gradation-256.timeline.svg` renders the captured durations with the current
dependency topology and highlights the GPU/CPU overlap:

- Vulkan timestamp-query execution overlaps CPU-side submit/readback waiting.

CPU-side aggregation is sequential: the comparison processes scale 0 first,
then processes scales 1-4 in order on the same CPU execution path. The
postprocess spans in the timeline preserve that order. The numeric bucket
durations are retained from the original capture and are not a current
performance benchmark.

The timestamp-query duration is exact, but this profiler does not calibrate the
GPU timestamp clock against the CPU clock. Its horizontal placement inside the
submit/wait window is therefore schematic. Other displayed durations are the
values retained from the original capture.

Validate the timeline source with the bundled parser:

```powershell
& node --experimental-strip-types `
    .\tools\profiling\dependency_timeline\Test-program\runnner.ts `
    .\tools\profiling\dependency_timeline\Results\gradation-256.timeline.txt
```
