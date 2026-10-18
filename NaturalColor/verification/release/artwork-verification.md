# Native artwork verification — 17 October 2026

[Hosted run 39037816177](https://github.com/normiecore/dashcam-claude/actions/runs/39037816177) successfully rendered four privately supplied original RAWs through the verified 0.1.2 iOS PhotoEngine and NaturalKernel. The source guard confirms production app inputs match `9744adf493c837c32f8663ac14f5aef04511ff5f`. Production app code was not altered for the imagery task.

All four native HEICs are 6048 × 8064 at Medium quality (0.78), native framing, finish 1 and exposure 0. File sizes range from 2.58–7.07 MB. Each presentation JPEG was decoded from its final encoded HEIC at a 2400px maximum edge; there is no additional creative grade or crop. Source RAW checksums, returned native/preview checksums and dimensions were verified locally. This exercises RAW import/render/export on an iPhone Simulator, not physical camera capture.

The selection emphasises frond lines, a circular sculpture, pennant triangles and architectural framing. The new private board supersedes the earlier study’s older-build imagery. Native exports, the rendering manifest, verification summary, standalone gallery and PNG board remain outside the public repository in the task’s private assessment workspace. No private photographs, original filenames, Drive IDs, authenticated download URLs or user metadata are published here.

The CI harness decrypts a short-lived input envelope using the existing Actions-only key and a task-specific encryption context. Outputs are encrypted to a workspace-generated recipient before artifact upload; only ciphertext is uploaded, with one-day retention. The workspace private return key is never committed. The expired input envelope is removed from the active branch after completion. Future runs need fresh authorised input URLs and the matching private return recipient; the harness does not upload an app or change Apple metadata.

The first run passed native rendering but its post-test `simctl` lookup failed because the queried simulator was shut down. The accepted run collects from the authoritative directory reported by the test, independently of simulator boot state. All four outputs were retrieved and validated.

See `app-store/names.md` for the expanded naming brief. Final branding and publication assets remain subject to the user’s selection; no App Store artwork has been submitted.
