# Rendering of a chromatogram

## Usage

```text
ABIF Chromatogram Generator
Version: 0.3.0

Usage: abichromatogram <trace_file.ab1> [options]

Description:
  Generates an SVG chromatogram from an ABIF trace file,
  displaying the four fluorescence channels with base calls.

Options:
  -o, --output FILE       Output SVG file (default: chromatogram.svg)
      --html FILE         Output a portable HTML report with embedded SVG
  -w, --width WIDTH       SVG width in pixels (default: 1200)
      --height HEIGHT     SVG height in pixels (default: 600)
  -s, --start POS         Start position (default: 0)
  -e, --end POS           End position (default: whole trace)
  -d, --downsample FACTOR Downsample factor for smoother visualization (default: 1)
      --highlight START-END
                          Highlight a trace scan region; repeat or comma-separate
      --hide-bases        Hide base calls
      --debug             Show debug information
  -h, --help              Show this help message and exit
  -v, --version           Show version information and exit

Examples:
  abichromatogram input.ab1
  abichromatogram input.ab1 -o output.svg -d 5
  abichromatogram input.ab1 --html output.html
  abichromatogram input.ab1 -s 500 -e 1000 --width 1600
  abichromatogram input.ab1 --highlight 540-620,780-830
```

## Example

```bash
abichromatogram tests/A_forward.ab1 -o A.svg -s 500 -e 1000 --width 1600
```
![screenshot](chromas.png)
