# Compositor golden corpus

Reference artifacts produced by the **real macOS Compositor code**, used as the behavioral
baseline for the Windows (C#/.NET) port.

The Windows port cannot be checked against the Mac app directly — there is no Mac in the port's
development loop. So this repository exists to run the original Swift code on a macOS CI runner
and capture what it actually produces: manifest bytes, pixel buffers, parsed values. The port is
then tested against those captures. Without this, "the port looks right" is the only available
standard.

- **Source**: derived from <https://github.com/robbietilton/Compositor> at commit `24ef288` ("Version 1.4.8"), MIT licensed — see [`LICENSE`](LICENSE). Upstream's own readme is kept as [`README-upstream.md`](README-upstream.md).
- **Purpose**: artifact generation only. This is not a fork intended for upstream contribution.
- **Relationship to the Windows port**: the port lives in a separate repository. This one is pinned to the commit above on purpose: a moving baseline is not a baseline.

## Generating the corpus

The `Golden corpus` workflow is **manual** (`workflow_dispatch`). Run it from the Actions tab.

It runs one suite — `GoldenDump` — which writes artifacts instead of asserting, then uploads
them as the `golden-corpus` artifact. The generated manifest is also printed into the job log,
so formatting questions can often be answered without downloading anything.

Locally, the same thing with:

```sh
xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:CompositorTests/GoldenDump
```

Output lands in `golden-out/` at the repository root (override with `GOLDEN_DUMP_DIR`).

## What is in it

| Artifact | What it pins |
|---|---|
| `001-minimal.manifest.json` | Raw `manifest.json` bytes: indentation, spacing around `:`, and how `/` and non-ASCII are escaped. The layer name deliberately contains both. |
| `002-resave.manifest.json` | Whether save → load → save reproduces identical bytes. If it does not, no byte-exact golden is trustworthy until that is understood. |
| `003-adjustments.manifest.json` | One layer per adjustment kind with non-default settings: the adjustment key names, which optional members are omitted, and how whole doubles and `UInt32` seeds are written. Every value is a fixed literal, so the port can rebuild the same logical document and compare byte for byte. |
| `004-hsv.manifest.json` | What the unstable `hsvSettings` dictionaries looked like in this run, saved twice to show whether even a single process repeats its own order. Compare semantically; see below. |
| `tree.json` | Sorted path / size / SHA-256 for every file in each package, so a consumer never has to enumerate a filesystem to know what a golden contains. |
| `metadata.json` | Manifest version, supported version range, macOS version, physical memory. Several limits are machine-dependent, so a diff is only meaningful alongside this. |

## Things that will bite you

Two hazards make naive byte-for-byte comparison wrong. Both are real and both are reachable from
ordinary documents.

- **`hsvSettings.adjustments` / `.bands` are not stable.** They are `[ColorRange: …]`, and
  `ColorRange` does not conform to `CodingKeyRepresentable`, so Swift encodes them as *unkeyed
  alternating key/value arrays* in per-process randomized hash order. `.sortedKeys` cannot
  reorder an unkeyed container. Normalize or compare these semantically.
- **Limits follow the machine.** The document pixel budget is derived from physical memory, and
  it is interpolated into the "too large" error text. A document valid on a large runner can be
  rejected on a small one, with a different message.

## Layout

```
Compositor/            the app, unchanged
CompositorTests/       the test suite, plus GoldenDump.swift (the generator)
docs/                  first-party format documentation — project-format.md is authoritative
.github/workflows/     golden-corpus.yml (manual dump) + verify.yml (the original CI)
```

`GoldenDump.swift` lives inside `CompositorTests` rather than in a target of its own because
that target's sources are a `PBXFileSystemSynchronizedRootGroup`: adding a file to the folder is
enough, with no `project.pbxproj` change. It is excluded from `verify.yml`, so it can never fail
normal CI.

## License

MIT, inherited from upstream. See [`LICENSE`](LICENSE).
