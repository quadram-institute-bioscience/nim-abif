# Changelog

## 0.3.0

- Added `abiscreen`, a threaded batch hotspot-screening CLI for `.ab1` traces, with reference-panel alignment, orientation detection, CSV/VCF output, and self-contained HTML reports with per-call chromatogram evidence.
- Added `abivalidate` for aligning ABIF reads to FASTA references and emitting variant calls as VCF, with optional summary-table output.
- Expanded `abichromatogram` beyond SVG export with reusable in-memory rendering, trace-region highlights, and a portable interactive HTML viewer with zooming, scrolling, metadata, and sequence navigation.
- Hardened `abi2fq` conversion with FASTA output, post-trim minimum-length checks, safer record naming, Phred+33 validation, stderr-only diagnostics, and explicit IUPAC ambiguity modes (`preserve`, `mask`, `enumerate`).
- Improved paired-read merging with shared quality trimming, FASTA output, stricter alignment controls, no-overlap joining, and better orientation/reverse-complement handling.
- Fixed ABIF 32-bit big-endian integer decoding so large directory/data offsets remain positive, and made `abimetadata` tag editing use bounded in-process writes instead of shell-script patching.
- Raised the package baseline to Nim 2.2.0, added `readfx` and `malebolgia`, and broadened regression coverage for parsing, conversion, trimming, chromatogram HTML, metadata editing, and hotspot-screening fixtures.
