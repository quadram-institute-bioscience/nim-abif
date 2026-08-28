## abiscreen - batch hotspot mutation screening across many .ab1 traces
##
## Aligns each trace against a panel of reference amplicons (auto-detecting
## orientation), calls the state at each user-defined hotspot position, and
## writes a batch report (CSV, VCF, and a self-contained HTML page with
## per-call chromatogram evidence). Files are processed in parallel via a
## `malebolgia` thread pool.
##
## Command-line usage:
##
## .. code-block:: none
##   abiscreen --input traces/ --targets hotspots.tsv --reference refs.fa \
##             --outdir results/ [options]
##
## Options:
##   -i, --input DIR|FILE       Directory of .ab1 files or a single file (repeatable)
##   -p, --targets FILE         Hotspot panel TSV (required)
##   -r, --reference FILE       Reference FASTA matching the panel's ref_name column (required)
##   -o, --outdir DIR           Output directory (required)
##       --min-q INT            Minimum quality at the target position (default: 20)
##       --window INT           Flanking bases either side in evidence panels (default: 12)
##       --threads INT          Worker thread pool size (default: CPU count)
##       --report LIST          Comma list of html,csv,vcf to emit (default: all)
##       --min-identity FLOAT   Minimum alignment identity (default: 0.65)
##       --min-coverage FLOAT   Minimum alignment coverage of the read (default: 0.10;
##                              coverage is relative to the READ, and hotspot
##                              references are usually much shorter than the
##                              read, so a low default is intentional)
##   -v, --verbose              Verbose output
##   -h, --help                 Show this help message
##       --version              Show version information

import std/[os, strformat, strutils, sequtils, algorithm, tables, cpuinfo]
import malebolgia
import ./abif
import ./aligner
import ./abichromatogram

type
  ReportFormat = enum
    rfHtml = "html"
    rfCsv = "csv"
    rfVcf = "vcf"

  Target = object
    assayId, refName: string
    position: int ## 1-based coordinate in the matching reference sequence
    refBase, altBase: char
    gene, tag, strand: string

  CallCategory = enum
    ccReference = "Reference"
    ccVariant = "Variant"
    ccHeterozygous = "Heterozygous"
    ccAmbiguous = "Ambiguous"
    ccFailedQC = "FailedQC"

  LocusCall = object
    sample, assayId, gene, tag, refName: string
    position: int
    refBase, altBase: char
    observed: string
    category: CallCategory
    confidence: float ## fraction of raw peak signal at this position attributable to altBase
    quality: int
    orientation: string
    reason: string
    evidenceSvg: string
    evidenceFile: string

  SampleOutcome = object
    sample: string
    ok: bool
    failReason: string
    orientation: string
    identity, coverage: float
    calls: seq[LocusCall]

  Config = object
    inputs: seq[string]
    targetsFile, referenceFile, outdir: string
    minQ: int
    window: int
    threads: int
    reportFormats: set[ReportFormat]
    minIdentity, minCoverage: float
    verbose: bool

proc getVersion(): string =
  let ver = abifVersion()
  if ver == "<NimblePkgVersion>": "0.1.0" else: ver

proc showVersion() =
  echo fmt"abiscreen {getVersion()}"

proc showHelp() =
  echo """
abiscreen - batch hotspot mutation screening across many .ab1 traces

Usage:
  abiscreen --input traces/ --targets hotspots.tsv --reference refs.fa \
            --outdir results/ [options]

Options:
  -i, --input DIR|FILE       Directory of .ab1 files or a single file (repeatable)
  -p, --targets FILE         Hotspot panel TSV (required)
  -r, --reference FILE       Reference FASTA matching the panel's ref_name column (required)
  -o, --outdir DIR           Output directory (required)
      --min-q INT            Minimum quality at the target position (default: 20)
      --window INT           Flanking bases either side in evidence panels (default: 12)
      --threads INT          Worker thread pool size (default: CPU count)
      --report LIST          Comma list of html,csv,vcf to emit (default: all)
      --min-identity FLOAT   Minimum alignment identity (default: 0.65)
      --min-coverage FLOAT   Minimum alignment coverage of the read (default: 0.10;
                             coverage is relative to the READ, and hotspot
                             references are usually much shorter than the
                             read, so a low default is intentional)
  -v, --verbose              Verbose output
  -h, --help                 Show this help message
      --version              Show version information

Example:
  abiscreen -i datasets/5865470/mutation -i datasets/5865470/no_mutation \
            -p targets.tsv -r refs.fa -o results/
"""

# ---------------------------------------------------------------------------
# CLI parsing (manual loop, not std/parseopt: parseopt does not bind a
# following space-separated argument as an option's value, only `-o:value`
# or `-o=value` forms - it would silently break the space-separated syntax
# this tool documents and that its users will actually type)
# ---------------------------------------------------------------------------

proc parseArgs(): Config =
  result = Config(
    minQ: 20,
    window: 12,
    threads: max(1, countProcessors()),
    reportFormats: {rfHtml, rfCsv, rfVcf},
    minIdentity: 0.65,
    minCoverage: 0.10,
    verbose: false
  )

  proc requireValue(flag: string, i, count: int) =
    if i > count:
      stderr.writeLine fmt"Error: Missing value for {flag}"
      quit(1)

  var i = 1
  let count = paramCount()
  while i <= count:
    let arg = paramStr(i)
    case arg
    of "-h", "--help":
      showHelp()
      quit(0)
    of "--version":
      showVersion()
      quit(0)
    of "-v", "--verbose":
      result.verbose = true
      inc i
    of "-i", "--input":
      requireValue(arg, i + 1, count)
      result.inputs.add(paramStr(i + 1))
      i += 2
    of "-p", "--targets":
      requireValue(arg, i + 1, count)
      result.targetsFile = paramStr(i + 1)
      i += 2
    of "-r", "--reference":
      requireValue(arg, i + 1, count)
      result.referenceFile = paramStr(i + 1)
      i += 2
    of "-o", "--outdir":
      requireValue(arg, i + 1, count)
      result.outdir = paramStr(i + 1)
      i += 2
    of "--min-q":
      requireValue(arg, i + 1, count)
      result.minQ = parseInt(paramStr(i + 1))
      i += 2
    of "--window":
      requireValue(arg, i + 1, count)
      result.window = parseInt(paramStr(i + 1))
      i += 2
    of "--threads":
      requireValue(arg, i + 1, count)
      result.threads = max(1, parseInt(paramStr(i + 1)))
      i += 2
    of "--report":
      requireValue(arg, i + 1, count)
      result.reportFormats = {}
      for f in paramStr(i + 1).split(","):
        case f.strip().toLowerAscii
        of "html": result.reportFormats.incl(rfHtml)
        of "csv": result.reportFormats.incl(rfCsv)
        of "vcf": result.reportFormats.incl(rfVcf)
        else:
          stderr.writeLine fmt"Error: Unknown report format '{f}'"
          quit(1)
      i += 2
    of "--min-identity":
      requireValue(arg, i + 1, count)
      result.minIdentity = parseFloat(paramStr(i + 1))
      i += 2
    of "--min-coverage":
      requireValue(arg, i + 1, count)
      result.minCoverage = parseFloat(paramStr(i + 1))
      i += 2
    else:
      stderr.writeLine fmt"Error: Unknown argument '{arg}'"
      quit(1)

  if result.targetsFile == "":
    stderr.writeLine "Error: --targets is required"
    quit(1)
  if result.referenceFile == "":
    stderr.writeLine "Error: --reference is required"
    quit(1)
  if result.outdir == "":
    stderr.writeLine "Error: --outdir is required"
    quit(1)
  if result.inputs.len == 0:
    stderr.writeLine "Error: at least one --input is required"
    quit(1)

# ---------------------------------------------------------------------------
# Panel / input loading
# ---------------------------------------------------------------------------

proc parseTargets(path: string): seq[Target] =
  var headerSeen = false
  for rawLine in lines(path):
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if not headerSeen:
      headerSeen = true
      continue # skip the column-header row
    let cols = line.split('\t')
    if cols.len < 5:
      raise newException(ValueError, "targets.tsv: expected at least 5 columns, got: " & line)
    var t = Target(
      assayId: cols[0],
      refName: cols[1],
      position: parseInt(cols[2]),
      refBase: cols[3][0].toUpperAscii,
      altBase: cols[4][0].toUpperAscii
    )
    if cols.len > 5: t.gene = cols[5]
    if cols.len > 6: t.tag = cols[6]
    if cols.len > 7: t.strand = cols[7]
    result.add(t)

proc listAbiFiles(inputs: seq[string]): seq[string] =
  for inp in inputs:
    if dirExists(inp):
      for f in walkFiles(inp / "*.ab1"):
        result.add(f)
    elif fileExists(inp):
      result.add(inp)
    else:
      stderr.writeLine fmt"Warning: input path does not exist, skipping: {inp}"
  result.sort()

# ---------------------------------------------------------------------------
# Raw peak amplitude access (for the confidence metric) - separate from
# abichromatogram's getTraceData, which normalizes each channel against its
# own global max for display and is not suitable for a true cross-channel
# ratio at a single position.
# ---------------------------------------------------------------------------

type
  RawChannels = object
    order: array[4, char] ## base identity of DATA9-12 (or DATA1-4), from FWO_1
    data: array[4, seq[int]]
    ploc: seq[int] ## trace scan position of each called base, from PLOC2

proc parseIntArray(raw: string): seq[int] =
  let inner = raw.strip(chars = {'@', '[', ']'})
  if inner.len == 0:
    return @[]
  for part in inner.split(","):
    let p = part.strip()
    if p.len > 0:
      result.add(parseInt(p))

proc loadRawChannels(trace: ABIFTrace): RawChannels =
  var fwo = trace.getData("FWO_1")
  if fwo.len < 4:
    fwo = "GATC"
  let useProcessed = trace.getTagNames().anyIt(it == "DATA9")
  let channelNames = if useProcessed: ["DATA9", "DATA10", "DATA11", "DATA12"]
                      else: ["DATA1", "DATA2", "DATA3", "DATA4"]
  for i in 0..3:
    result.order[i] = fwo[i].toUpperAscii
    result.data[i] = parseIntArray(trace.getData(channelNames[i]))
  result.ploc = parseIntArray(trace.getData("PLOC2"))

proc amplitudesAt(rc: RawChannels, calledBaseIndex: int): Table[char, int] =
  if calledBaseIndex < 0 or calledBaseIndex >= rc.ploc.len:
    return
  let scanPos = rc.ploc[calledBaseIndex]
  for i in 0..3:
    if scanPos < rc.data[i].len:
      result[rc.order[i]] = rc.data[i][scanPos]

proc complementBase(c: char): char =
  case c.toUpperAscii
  of 'A': 'T'
  of 'T': 'A'
  of 'C': 'G'
  of 'G': 'C'
  else: 'N'

# ---------------------------------------------------------------------------
# Targeted locus classification
# ---------------------------------------------------------------------------

proc mapRefPosToAlignedIndex(aln: AlignmentResult, targetPos1based: int): int =
  ## Index into aln.refAligned/abiAligned for a 1-based reference position,
  ## or -1 if the alignment doesn't cover that position.
  let targetPos0 = targetPos1based - 1
  if targetPos0 < aln.refStart or targetPos0 > aln.refEnd:
    return -1
  var refPos = aln.refStart
  for i in 0..<aln.refAligned.len:
    if aln.refAligned[i] != '-':
      if refPos == targetPos0:
        return i
      inc refPos
  -1

proc classifyLocus(target: Target, aln: AlignmentResult, abiQual: seq[int],
                    rc: RawChannels, originalLen: int, minQ: int): LocusCall =
  result = LocusCall(
    assayId: target.assayId, gene: target.gene, tag: target.tag,
    refName: target.refName, position: target.position,
    refBase: target.refBase, altBase: target.altBase,
    orientation: (if aln.isReverseComplement: "reverse complement" else: "forward")
  )

  let idx = mapRefPosToAlignedIndex(aln, target.position)
  if idx < 0:
    result.category = ccFailedQC
    result.reason = "target position not covered by alignment"
    return

  let abiBase = aln.abiAligned[idx].toUpperAscii
  var abiPos = aln.abiStart
  for i in 0..<idx:
    if aln.abiAligned[i] != '-':
      inc abiPos

  if abiBase == '-':
    result.category = ccFailedQC
    result.reason = "alignment gap at target position"
    return

  result.observed = $abiBase
  result.quality = if abiPos < abiQual.len: abiQual[abiPos] else: 0

  let origIdx = if aln.isReverseComplement: originalLen - 1 - abiPos else: abiPos
  let physicalAlt = if aln.isReverseComplement: complementBase(target.altBase) else: target.altBase
  let amps = rc.amplitudesAt(origIdx)
  var total = 0
  for _, v in amps: total += v
  result.confidence = if total > 0: amps.getOrDefault(physicalAlt, 0).float / total.float else: 0.0

  let alleles = iupacAlleles(abiBase)
  let refU = target.refBase.toUpperAscii
  let altU = target.altBase.toUpperAscii

  # --min-q only gates a "looks like wild-type" call: a mixed/heterozygous
  # peak inherently gets a LOW base-caller quality score (it doesn't cleanly
  # match a single channel), so gating on quality unconditionally would
  # silently convert real heterozygous/variant calls into FailedQC - exactly
  # backwards for a mutation screen. Confirmed against this project's own
  # SangeR dataset fixtures: every true heterozygous hotspot call in
  # tests/fixtures/5865470 carries a base quality well below 20.
  if alleles == {refU}:
    if result.quality < minQ:
      result.category = ccFailedQC
      result.reason = fmt"quality {result.quality} below --min-q {minQ}"
    else:
      result.category = ccReference
  elif refU in alleles and altU in alleles:
    result.category = ccHeterozygous
  elif alleles == {altU}:
    result.category = ccVariant
  else:
    result.category = ccAmbiguous
    result.reason = fmt"observed '{abiBase}' matches neither ref '{refU}' nor alt '{altU}'"

# ---------------------------------------------------------------------------
# Per-file processing (runs inside the malebolgia thread pool)
# ---------------------------------------------------------------------------

proc renderEvidence(trace: ABIFTrace, rc: RawChannels, originalIdx: int,
                     window: int, sampleName: string): string =
  if originalIdx < 0 or rc.ploc.len == 0:
    return ""
  let data = getTraceData(trace)
  let loIdx = max(0, originalIdx - window)
  let hiIdx = min(rc.ploc.high, originalIdx + window)
  if loIdx >= rc.ploc.len or hiIdx < 0 or loIdx > hiIdx:
    return ""
  let startPos = max(0, rc.ploc[loIdx] - 5)
  let endPos = rc.ploc[hiIdx] + 5
  renderChromatogramSvg(data, sampleName, width = 900, height = 380,
                         showBaseCalls = true, startPos = startPos, endPos = endPos)

proc processOneFile(filename: string, targets: seq[Target], references: seq[RefSequence],
                     alignCfg: AlignConfig, minQ, window: int,
                     emitEvidence: bool, evidenceDir: string): SampleOutcome {.gcsafe.} =
  let sampleName = filename.extractFilename.changeFileExt("")
  result = SampleOutcome(sample: sampleName)

  try:
    let trace = newABIFTrace(filename)
    defer: trace.close()

    let sequence = trace.getSequence()
    let qualities = trace.getQualityValues()

    let (bestRef, aln, qual) = findBestAlignment(sequence, qualities, references, alignCfg)
    result.ok = true
    result.orientation = if aln.isReverseComplement: "reverse complement" else: "forward"
    result.identity = aln.identity
    result.coverage = aln.coverage

    let rc = loadRawChannels(trace)

    for target in targets:
      if target.refName != bestRef.name:
        continue
      var call = classifyLocus(target, aln, qual, rc, sequence.len, minQ)
      call.sample = sampleName

      if emitEvidence and call.category != ccFailedQC:
        let idx = mapRefPosToAlignedIndex(aln, target.position)
        if idx >= 0:
          var abiPos = aln.abiStart
          for i in 0..<idx:
            if aln.abiAligned[i] != '-': inc abiPos
          let origIdx = if aln.isReverseComplement: sequence.len - 1 - abiPos else: abiPos
          let svg = renderEvidence(trace, rc, origIdx, window, sampleName)
          if svg.len > 0:
            call.evidenceSvg = svg
            call.evidenceFile = "evidence" / fmt"{sampleName}_{target.assayId}.svg"
            writeFile(evidenceDir / fmt"{sampleName}_{target.assayId}.svg", svg)

      result.calls.add(call)

  except CatchableError as e:
    result.ok = false
    result.failReason = e.msg

# ---------------------------------------------------------------------------
# Report writers
# ---------------------------------------------------------------------------

proc csvField(s: string): string =
  s.replace(",", ";")

proc writeCallsCsv(outcomes: seq[SampleOutcome], path: string) =
  var f = open(path, fmWrite)
  defer: f.close()
  f.writeLine("sample,assay_id,gene,tag,ref_name,position,ref_base,alt_base,observed,category,confidence,quality,orientation,reason")
  for o in outcomes:
    if not o.ok: continue
    for c in o.calls:
      f.writeLine(@[
        csvField(c.sample), csvField(c.assayId), csvField(c.gene), csvField(c.tag),
        csvField(c.refName), $c.position, $c.refBase, $c.altBase, csvField(c.observed),
        $c.category, fmt"{c.confidence:.3f}", $c.quality, csvField(c.orientation),
        csvField(c.reason)
      ].join(","))

proc writeFailedCsv(outcomes: seq[SampleOutcome], path: string) =
  var f = open(path, fmWrite)
  defer: f.close()
  f.writeLine("sample,reason")
  for o in outcomes:
    if not o.ok:
      f.writeLine(@[csvField(o.sample), csvField(o.failReason)].join(","))

proc writeCallsVcf(outcomes: seq[SampleOutcome], path: string, referenceFile: string) =
  type VariantKey = tuple[refName: string, position: int, refBase, altBase: char, gene, tag, assayId: string]
  var order: seq[VariantKey] = @[]
  var genotypes = initTable[VariantKey, Table[string, string]]() # key -> sample -> GT

  for o in outcomes:
    if not o.ok: continue
    for c in o.calls:
      if c.category notin {ccVariant, ccHeterozygous}: continue
      let key: VariantKey = (c.refName, c.position, c.refBase, c.altBase, c.gene, c.tag, c.assayId)
      if key notin genotypes:
        genotypes[key] = initTable[string, string]()
        order.add(key)
      genotypes[key][o.sample] = (if c.category == ccHeterozygous: "0/1" else: "1/1")

  let samples = outcomes.filterIt(it.ok).mapIt(it.sample).deduplicate().sorted()

  var f = open(path, fmWrite)
  defer: f.close()
  f.writeLine("##fileformat=VCFv4.2")
  f.writeLine(fmt"##source=abiscreen-{getVersion()}")
  f.writeLine(fmt"##reference={referenceFile}")
  f.writeLine("##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">")
  f.writeLine((@["#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT"] & samples).join("\t"))

  for key in order:
    let sampleGts = genotypes[key]
    let info = fmt"GENE={key.gene};TAG={key.tag};ASSAY={key.assayId}"
    var gtCols: seq[string] = @[]
    for s in samples:
      gtCols.add(sampleGts.getOrDefault(s, "./."))
    f.writeLine((@[
      key.refName, $key.position, ".", $key.refBase, $key.altBase, ".",
      "PASS", info, "GT"
    ] & gtCols).join("\t"))

proc htmlEscape(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

proc writeRunHtml(outcomes: seq[SampleOutcome], path: string) =
  var counts = initTable[string, int]()
  var totalCalls = 0
  for o in outcomes:
    for c in o.calls:
      counts.mgetOrPut($c.category, 0).inc()
      inc totalCalls

  var body = """
<!doctype html><html><head><meta charset="utf-8">
<title>abiscreen report</title>
<style>
body { font-family: -apple-system, Arial, sans-serif; margin: 2rem; color: #1a1a1a; }
h1 { font-size: 1.4rem; }
table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
th, td { border: 1px solid #ddd; padding: 6px 10px; font-size: 0.9rem; text-align: left; }
th { background: #f4f4f4; }
tr.Reference { color: #666; }
tr.Variant { background: #fff4e5; }
tr.Heterozygous { background: #fff0f0; }
tr.Ambiguous { background: #f0f0ff; }
tr.FailedQC { background: #f0f0f0; color: #888; }
.summary { display: flex; gap: 1.5rem; margin: 1rem 0; }
.stat { border: 1px solid #ddd; border-radius: 6px; padding: 0.5rem 1rem; }
.stat b { display: block; font-size: 1.3rem; }
details summary { cursor: pointer; }
</style></head><body>
"""
  body.add fmt"<h1>abiscreen report</h1><p>{outcomes.len} samples, {totalCalls} calls</p>"
  body.add "<div class=\"summary\">"
  for cat in ["Reference", "Variant", "Heterozygous", "Ambiguous", "FailedQC"]:
    body.add fmt"""<div class="stat"><b>{counts.getOrDefault(cat, 0)}</b>{cat}</div>"""
  let failedCount = outcomes.filterIt(not it.ok).len
  body.add fmt"""<div class="stat"><b>{failedCount}</b>Failed samples</div>"""
  body.add "</div>"

  body.add "<table><tr><th>Sample</th><th>Assay</th><th>Gene / Tag</th><th>Position</th>" &
           "<th>Ref &gt; Alt</th><th>Observed</th><th>Call</th><th>Confidence</th>" &
           "<th>Quality</th><th>Orientation</th><th>Evidence</th></tr>"

  for o in outcomes:
    if not o.ok:
      body.add fmt"""<tr class="FailedQC"><td>{htmlEscape(o.sample)}</td><td colspan="9">Failed: {htmlEscape(o.failReason)}</td></tr>"""
      continue
    for c in o.calls:
      body.add fmt"""<tr class="{c.category}">"""
      body.add fmt"<td>{htmlEscape(c.sample)}</td><td>{htmlEscape(c.assayId)}</td>"
      body.add fmt"<td>{htmlEscape(c.gene)} / {htmlEscape(c.tag)}</td><td>{c.position}</td>"
      body.add fmt"<td>{c.refBase} &gt; {c.altBase}</td><td>{htmlEscape(c.observed)}</td>"
      body.add fmt"<td>{c.category}</td><td>{c.confidence:.2f}</td><td>{c.quality}</td>"
      body.add fmt"<td>{htmlEscape(c.orientation)}</td><td>"
      if c.evidenceSvg.len > 0:
        body.add fmt"<details><summary>view</summary>{c.evidenceSvg}</details>"
      body.add "</td></tr>"
  body.add "</table></body></html>"
  writeFile(path, body)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() =
  let config = parseArgs()

  if config.verbose:
    echo fmt"Loading targets from {config.targetsFile}..."
  let targets = parseTargets(config.targetsFile)
  if config.verbose:
    echo fmt"Loaded {targets.len} targets"

  if config.verbose:
    echo fmt"Loading reference sequences from {config.referenceFile}..."
  let references = loadReference(config.referenceFile)
  if config.verbose:
    echo fmt"Loaded {references.len} reference sequences"

  let files = listAbiFiles(config.inputs)
  if files.len == 0:
    stderr.writeLine "Error: no .ab1 files found in the given --input path(s)"
    quit(1)
  if config.verbose:
    echo fmt"Found {files.len} .ab1 files"

  createDir(config.outdir)
  let evidenceDir = config.outdir / "evidence"
  let emitEvidence = rfHtml in config.reportFormats
  if emitEvidence:
    createDir(evidenceDir)

  let alignCfg = AlignConfig(minIdentity: config.minIdentity, minCoverage: config.minCoverage,
                             scoreMatch: 10, scoreMismatch: -8, scoreGap: -10)

  var results = newSeq[SampleOutcome](files.len)
  var m = createMaster()
  m.awaitAll:
    for i, f in files:
      m.spawn processOneFile(f, targets, references, alignCfg, config.minQ, config.window,
                              emitEvidence, evidenceDir) -> results[i]

  results.sort(proc(a, b: SampleOutcome): int = cmp(a.sample, b.sample))

  if rfCsv in config.reportFormats:
    writeCallsCsv(results, config.outdir / "calls.csv")
    writeFailedCsv(results, config.outdir / "failed.csv")
  if rfVcf in config.reportFormats:
    writeCallsVcf(results, config.outdir / "calls.vcf", config.referenceFile)
  if rfHtml in config.reportFormats:
    writeRunHtml(results, config.outdir / "run.html")

  let okCount = results.filterIt(it.ok).len
  echo fmt"Processed {files.len} files ({okCount} aligned, {files.len - okCount} failed). Output: {config.outdir}"

when isMainModule:
  main()
