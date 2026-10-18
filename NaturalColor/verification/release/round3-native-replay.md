# Round 3 native same-input replay — 18 October 2026

Two private Round 3 ProRAW originals were developed with the original 0.1.1 engine and the accepted 0.1.3 engine. Both engines produced byte-identical 1600-pixel previews and byte-identical full-resolution sRGB RGBA8 rasters on each original. Zero-strength decoder previews also matched. The rollback therefore restores the original rendering behavior for these inputs in this simulator environment.

Successful native run: https://github.com/normiecore/dashcam-claude/actions/runs/39119748186. The single private XCTest passed in 348.593 seconds. Workflow source: `b39bf05`; encrypted references arrived separately at `ad75341`. The app tree was guarded against accepted 0.1.3 source `0d405590144995297c5d4ab1faa9bb2beebccc66`. Original engine source was `5365cfa6f202c023132ab4fd6cb95d4859d3564f`; restored kernel and assets were guarded byte-for-byte against that source.

Engine source snapshots were compiled into tests, with type prefixes and an additional full-raster inspection method. Asset filename literals were preserved. The current live app engine additionally supplied its preview, high-quality JPEG and Medium HEIC exports. The original engine supplied its 0.96-quality JPEG. Settings were native aspect, strength 1 and exposure 0. All native products were 6048 × 8064; JPEG carried sRGB and HEIC carried Display P3.

Full encoded files were independently decoded with Pillow/libheif, transformed from embedded ICC profiles to sRGB using LittleCMS, then resized identically to 1200 × 1600 with Lanczos. This produces the following RGB channel differences, measured in 8-bit sRGB code values:

| Comparison | Pair 1 mean absolute error | Pair 2 mean absolute error | 95th-percentile absolute error |
| --- | ---: | ---: | ---: |
| Original JPEG versus current JPEG | 0.0384 | 0.0127 | 0, 0 |
| Original JPEG versus current HEIC | 0.7863 | 0.6541 | 2, 2 |
| Actual Round 3 HEIC versus replayed current HEIC | 0.8711 | 0.6586 | 2, 2 |

The actual Round 3 outputs and fresh replay are visually close. These two pairs do not support blaming HEIC/Display P3 for a broad color regression. Codec-specific ImageIO thumbnail resampling initially produced much larger JPEG/HEIC pixel errors; those thumbnail-only values must not be interpreted as a color-management failure. Decoding the full images before applying a common resize removed that confound.

This is native iOS simulator rendering, not an additional phone capture or proof of identical Apple decoder behavior on every OS. The replay runner image was `macos-26-arm64/20261013.0424.1`. Independent runtime probe https://github.com/normiecore/dashcam-claude/actions/runs/39120043014 used the same image and reported macOS 26.6.2 (25G83), Xcode 26.6 (17F113), and the identical deterministic selection of iPhone 17 Pro with iOS 26.5 (23F77). The replay runtime is inferred from that matching image and selection; it was not recorded inside the replay job. Supplied captures identify iOS 27.0.1. The small actual-versus-replay differences do not establish a cause for remaining device/codec differences.

Photographs, full source mapping and return private keys remain outside Git. All four downloaded encrypted artifact ZIP digests matched GitHub's SHA256 records; the full AES-GCM payload authenticated and all native-output checksums verified. The private comparison board uses the common full-file decoding method and no extra grading. Encrypted input references have been removed from the active audit branch. The initial resource-prefix failure was an audit harness error and supplies no image evidence; a prepared memory-bounded duplicate was cancelled when the successful run completed. No app implementation, TestFlight build or existing PR was changed by this replay branch.
