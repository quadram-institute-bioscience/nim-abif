import std/[os, strformat, strutils, parseopt, sequtils, times, algorithm]
import ./abif
import ./aligner

## This module provides a command-line tool for validating ABI sequences against
## a reference FASTA file using Smith-Waterman alignment and variant calling.
##
## The abivalidate tool loads reference sequences from a FASTA file, then aligns
## each ABI sequence against the references to find the best match. If no suitable
## alignment is found in the forward orientation, it automatically tries the 
## reverse complement. It performs variant calling and outputs results in VCF format.
##
## Command-line usage:
##
## .. code-block:: none
##   abivalidate -r reference.fasta -o output.vcf file1.ab1 file2.ab1 ...
##
## Options:
##   -r, --reference FILE       Reference FASTA file (required)
##   -o, --output FILE          Output VCF file (required)
##   -h, --help                 Show help message
##   --version                  Show version information
##   --min-identity FLOAT       Minimum alignment identity (default: 0.80)
##   --min-coverage FLOAT       Minimum coverage of ABI sequence (default: 0.90)
##   --score-match INT          Score for match (default: 10)
##   --score-mismatch INT       Score for mismatch (default: -8)
##   --score-gap INT            Score for gap (default: -10)
##   -v, --verbose              Verbose output
##   -t, --table                Output summary table

type
  Config = object
    referenceFile: string
    outputFile: string
    abiFiles: seq[string]
    minIdentity: float
    minCoverage: float
    scoreMatch: int
    scoreMismatch: int
    scoreGap: int
    verbose: bool
    summaryTable: bool

  Variant = object
    chrom: string
    pos: int
    refAllele: string
    altAllele: string
    quality: float
    sample: string
  
  AlignmentSummary = object
    sampleName: string
    refName: string
    refStart: int
    refEnd: int
    identity: float
    coverage: float
    variants: int
    isReverseComplement: bool

proc showHelp() =
  echo """
abivalidate - Validate ABI sequences against reference FASTA

Usage:
  abivalidate -r reference.fasta -o output.vcf file1.ab1 [file2.ab1 ...]

Options:
  -r, --reference FILE       Reference FASTA file (required)
  -o, --output FILE          Output VCF file (required)
  -h, --help                 Show this help message
  --version                  Show version information
  --min-identity FLOAT       Minimum alignment identity (default: 0.80)
  --min-coverage FLOAT       Minimum coverage of ABI sequence (default: 0.90)
  --score-match INT          Score for match (default: 10)
  --score-mismatch INT       Score for mismatch (default: -8)
  --score-gap INT            Score for gap (default: -10)
  -v, --verbose              Verbose output
  -t, --table                Output summary table

Examples:
  abivalidate -r reference.fa -o variants.vcf sample1.ab1 sample2.ab1
  abivalidate -r ref.fa -o out.vcf --min-identity 0.85 *.ab1
  abivalidate -r ref.fa -o out.vcf --table *.ab1
"""

proc showVersion() =
  echo fmt"abivalidate {abifVersion()}"

proc parseArgs(): Config =
  result = Config(
    minIdentity: 0.80,
    minCoverage: 0.90,
    scoreMatch: 10,
    scoreMismatch: -8,
    scoreGap: -10,
    verbose: false,
    summaryTable: false
  )
  
  var p = initOptParser(commandLineParams())
  
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "r", "reference":
        result.referenceFile = p.val
      of "o", "output":
        result.outputFile = p.val
      of "h", "help":
        showHelp()
        quit(0)
      of "version":
        showVersion()
        quit(0)
      of "min-identity":
        result.minIdentity = parseFloat(p.val)
      of "min-coverage":
        result.minCoverage = parseFloat(p.val)
      of "score-match":
        result.scoreMatch = parseInt(p.val)
      of "score-mismatch":
        result.scoreMismatch = parseInt(p.val)
      of "score-gap":
        result.scoreGap = parseInt(p.val)
      of "v", "verbose":
        result.verbose = true
      of "t", "table":
        result.summaryTable = true
      else:
        echo fmt"Unknown option: {p.key}"
        quit(1)
    of cmdArgument:
      result.abiFiles.add(p.key)

  if result.referenceFile == "":
    echo "Error: Reference file (-r) is required"
    quit(1)
  if result.outputFile == "":
    echo "Error: Output file (-o) is required"
    quit(1)
  if result.abiFiles.len == 0:
    echo "Error: At least one ABI file is required"
    quit(1)

proc callVariants(alignment: AlignmentResult, abiQual: seq[int], sampleName: string): seq[Variant] =
  ## Calls variants from an alignment, using quality scores where available.
  ##
  ## Parameters:
  ##   alignment: The alignment result (refAligned/abiAligned are the aligned strings)
  ##   abiQual: Quality scores in the same orientation as abiAligned
  ##   sampleName: Name of the sample for the variant records
  ##
  ## Returns:
  ##   Sequence of variants found in the alignment
  result = @[]
  var refPos = alignment.refStart
  var abiPos = alignment.abiStart

  # Simple approach: only call SNVs, skip complex indels for now
  for i in 0..<alignment.refAligned.len:
    let refBase = alignment.refAligned[i]
    let abiBase = alignment.abiAligned[i]

    if refBase != '-' and abiBase != '-':
      # Both bases present - check for SNV
      let refUpper = refBase.toUpperAscii
      let abiUpper = abiBase.toUpperAscii

      # Only process valid nucleotides
      if isValidNucleotide(refUpper) and isValidNucleotide(abiUpper):
        if refUpper != abiUpper:
          # Check if it's an ambiguous base that's compatible
          if not isAmbiguousBaseCompatible(abiUpper, refUpper):
            # Real SNV - not compatible ambiguous base
            # Use quality score from the ABI read if available
            let qual = if abiPos < abiQual.len: abiQual[abiPos].float
                       else: 0.0
            result.add(Variant(
              chrom: alignment.refName,
              pos: refPos + 1,  # VCF is 1-based
              refAllele: $refUpper,
              altAllele: $abiUpper,
              quality: qual,
              sample: sampleName
            ))

      # Always increment reference position for non-gap reference bases
      inc refPos
      inc abiPos
    elif refBase != '-':
      # Reference has base, ABI has gap - still increment ref position
      inc refPos
    else:
      # ABI insertion (refBase == '-'), advance ABI position only
      inc abiPos

proc writeVCF(variants: seq[Variant], outputFile: string, referenceFile: string) =
  var file = open(outputFile, fmWrite)
  defer: file.close()
  
  # Write VCF header
  file.writeLine("##fileformat=VCFv4.2")
  file.writeLine("##fileDate=" & now().format("yyyyMMdd"))
  file.writeLine(fmt"##source=abivalidate-{abifVersion()}")
  file.writeLine(fmt"##reference={referenceFile}")
  
  # Format fields
  file.writeLine("##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">")
  file.writeLine("##FORMAT=<ID=DP,Number=1,Type=Integer,Description=\"Read Depth\">")
  
  # Get unique samples
  let samples = variants.mapIt(it.sample).deduplicate().sorted()
  
  # Group variants by position and alleles to avoid duplicates
  var variantMap: seq[tuple[chrom: string, pos: int, refAllele: string, altAllele: string, quality: float, samples: seq[string]]] = @[]

  for variant in variants:
    let key = (variant.chrom, variant.pos, variant.refAllele, variant.altAllele)
    var found = false

    for i in 0..<variantMap.len:
      if variantMap[i].chrom == key[0] and variantMap[i].pos == key[1] and
         variantMap[i].refAllele == key[2] and variantMap[i].altAllele == key[3]:
        variantMap[i].samples.add(variant.sample)
        # Keep the highest quality score for this variant
        if variant.quality > variantMap[i].quality:
          variantMap[i].quality = variant.quality
        found = true
        break

    if not found:
      variantMap.add((key[0], key[1], key[2], key[3], variant.quality, @[variant.sample]))
  
  # Write header line
  let headerCols = @["#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT"] & samples
  file.writeLine(headerCols.join("\t"))
  
  # Write consolidated variant records
  for varEntry in variantMap:
    let cols = @[
      varEntry.chrom,
      $varEntry.pos,
      ".",  # ID
      varEntry.refAllele,
      varEntry.altAllele,
      fmt"{varEntry.quality:.1f}",
      "PASS",  # FILTER
      ".",     # INFO
      "GT:DP"  # FORMAT
    ]
    
    # Add genotype calls for each sample
    var gtCols: seq[string] = @[]
    for sample in samples:
      if sample in varEntry.samples:
        gtCols.add("1/1:1")  # Homozygous alt call with depth 1
      else:
        gtCols.add("./.:0")  # Missing with depth 0
    
    file.writeLine((cols & gtCols).join("\t"))

proc toAlignConfig(config: Config): AlignConfig =
  AlignConfig(minIdentity: config.minIdentity, minCoverage: config.minCoverage,
              scoreMatch: config.scoreMatch, scoreMismatch: config.scoreMismatch,
              scoreGap: config.scoreGap)

proc processABIFile(filename: string, references: seq[RefSequence], config: Config): seq[Variant] =
  try:
    let trace = newABIFTrace(filename)
    defer: trace.close()

    let sequence = trace.getSequence()
    let qualities = trace.getQualityValues()
    let sampleName = extractFilename(filename).replace(".ab1", "")

    if config.verbose:
      echo fmt"Processing {sampleName}: {sequence.len} bp"

    let (bestRef, alignment, qual) = findBestAlignment(sequence, qualities, references, toAlignConfig(config))

    if config.verbose:
      let orient = if alignment.isReverseComplement: "reverse complement" else: "forward"
      echo fmt"  Best match: {bestRef.name} (identity: {alignment.identity:.3f}, coverage: {alignment.coverage:.3f}, orientation: {orient})"

    result = callVariants(alignment, qual, sampleName)

    if config.verbose:
      echo fmt"  Found {result.len} variants"

  except Exception as e:
    echo fmt"Error processing {filename}: {e.msg}"
    result = @[]

proc main() =
  let config = parseArgs()
  
  if config.verbose:
    echo fmt"Loading reference sequences from {config.referenceFile}..."
  
  let references = loadReference(config.referenceFile)
  
  if config.verbose:
    echo fmt"Loaded {references.len} reference sequences"
  
  var allVariants: seq[Variant] = @[]
  
  for abiFile in config.abiFiles:
    if not fileExists(abiFile):
      echo fmt"Warning: File {abiFile} does not exist, skipping"
      continue
    
    let variants = processABIFile(abiFile, references, config)
    allVariants.add(variants)
  
  # Sort variants by chromosome and position
  allVariants.sort(proc(a, b: Variant): int =
    let chromCmp = cmp(a.chrom, b.chrom)
    if chromCmp != 0: chromCmp else: cmp(a.pos, b.pos)
  )
  
  if config.verbose:
    echo fmt"Writing {allVariants.len} variants to {config.outputFile}..."
  
  writeVCF(allVariants, config.outputFile, config.referenceFile)
  
  echo fmt"Analysis complete. Found {allVariants.len} variants in {config.abiFiles.len} samples."

when isMainModule:
  main()