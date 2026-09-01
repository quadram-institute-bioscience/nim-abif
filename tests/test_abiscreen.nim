import std/[unittest, os, osproc, strutils, sequtils]
import ../src/abif

## Validates `abiscreen` against the real SangeR/vbac009 dataset
## (tests/datasets/5865470.md), following that document's 5-layer test plan.
##
## The dataset itself is real, gitignored data fetched on demand via
## tests/download_zenodo_5865470.sh - it is NOT checked into the repo. If it
## isn't present locally, every test below is skipped (not failed) with a
## message explaining how to fetch it, so a fresh clone / CI without the
## dataset doesn't hard-fail.

const
  DatasetDir = "datasets" / "5865470"
  MutationDir = DatasetDir / "mutation"
  NoMutationDir = DatasetDir / "no_mutation"
  FixturesDir = "tests" / "fixtures" / "5865470"
  TargetsFile = FixturesDir / "targets.tsv"
  ReferenceFile = FixturesDir / "refs.fa"
  GoldenFile = "tests" / "golden" / "5865470_calls.csv"
  BinPath = "bin" / "abiscreen"
  WorkDir = "tests" / "tmp_abiscreen_out"

let datasetAvailable = dirExists(MutationDir) and dirExists(NoMutationDir)

if not datasetAvailable:
  echo "SKIP test_abiscreen.nim: ", DatasetDir, " not found locally."
  echo "  Fetch it with: bash tests/download_zenodo_5865470.sh ", DatasetDir

type CallRow = object
  sample, assayId, gene, tag, refName: string
  position: int
  refBase, altBase, observed, category: string
  confidence: float
  quality: int
  orientation, reason: string

proc parseCallsCsv(path: string): seq[CallRow] =
  var first = true
  for line in lines(path):
    if first:
      first = false
      continue
    let f = line.split(",")
    result.add(CallRow(
      sample: f[0], assayId: f[1], gene: f[2], tag: f[3], refName: f[4],
      position: parseInt(f[5]), refBase: f[6], altBase: f[7], observed: f[8],
      category: f[9], confidence: parseFloat(f[10]), quality: parseInt(f[11]),
      orientation: f[12], reason: (if f.len > 13: f[13] else: "")
    ))

proc runAbiscreen(outdir: string): seq[CallRow] =
  removeDir(outdir)
  doAssert fileExists(BinPath), BinPath & " not built - run `nimble buildbin` first"
  let cmd = @[BinPath, "-i", MutationDir, "-i", NoMutationDir,
              "-p", TargetsFile, "-r", ReferenceFile,
              "-o", outdir, "--report", "csv"].join(" ")
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "abiscreen exited " & $exitCode & ":\n" & output
  parseCallsCsv(outdir / "calls.csv")

proc find(calls: seq[CallRow], sample, assayId: string): CallRow =
  for c in calls:
    if c.sample == sample and c.assayId == assayId:
      return c
  raise newException(ValueError, "no call found for " & sample & "/" & assayId)

let allCalls = if datasetAvailable: runAbiscreen(WorkDir) else: @[]

# --- Layer 1: file parsing (structural, no biology) ------------------------

test "Layer 1: every mutation/ and no_mutation/ file parses without error":
  if not datasetAvailable: skip()
  else:
    for dir in [MutationDir, NoMutationDir]:
      for f in walkFiles(dir / "*.ab1"):
        let trace = newABIFTrace(f)
        check trace.getSequence().len > 0
        check trace.getSequence().len == trace.getQualityValues().len
        trace.close()

# --- Layer 2: known-mutation detection (positive controls) -----------------

test "Layer 2: all 7 TERT promoter files called correctly":
  if not datasetAvailable: skip()
  else:
    check find(allCalls, "TERTp-G55_TERTp-fwd", "TERTp_C250").category == "Variant"
    for s in ["TERTp-HGBM_TERTp-fwd", "TERTp-U118_TERTp-fwd", "TERTp_G141_TERTp-9-fwd",
              "TERTp_GBM46x_TERTp-9-fwd", "TERTp_U87_TERTp-9-fwd"]:
      check find(allCalls, s, "TERTp_C228").category == "Variant"
    let lnCall = find(allCalls, "TERTp_LN-229_TERTp-9-fwd", "TERTp_C228")
    check lnCall.category == "Heterozygous"
    check lnCall.observed == "Y" # IUPAC ambiguity code for C228Y, not forced to C or T

test "Layer 2: IDH1 R132H called for patient_2":
  if not datasetAvailable: skip()
  else:
    let c = find(allCalls, "patient_2_IDH1", "IDH1_R132")
    check c.category == "Heterozygous"
    check c.observed == "R"

test "Layer 2: patient_1 does not stop scanning after one hit - G105G is also surfaced":
  if not datasetAvailable: skip()
  else:
    # Silent/synonymous variant on the same IDH1 read as R132 - must be
    # reported, not dropped as "no amino acid change" (doc §4.2/§4.4).
    check find(allCalls, "patient_1_IDH1", "IDH1_G105").category == "Variant"
    # A second target on the SAME read was still evaluated (doesn't stop at
    # the first hit): the discrete base call there is a clean Reference
    # (see the dedicated xfail below for why this isn't R132H).
    check find(allCalls, "patient_1_IDH1", "IDH1_R132").category == "Reference"

test "Layer 2: IDH2 R172M called for patient_3 (mutation/ copy only)":
  if not datasetAvailable: skip()
  else:
    # The root-level patient_3_IDH2.ab1 duplicate is intentionally excluded:
    # SMPL1 (6826981 vs B001366-21_NN_IDH2) and RUND1 (2016-04-14 vs
    # 2021-09-02) differ, and raw peak amplitudes show a genuinely different
    # heterozygous call (G/T vs G/A) at the analogous position - two
    # distinct samples, not the same signal at two thresholds (see
    # tests/datasets/5865470.md §3.2). Only mutation/ and no_mutation/ are
    # fed to abiscreen here, so the root copy never enters this test.
    let c = find(allCalls, "patient_3_IDH2", "IDH2_R172")
    check c.category == "Heterozygous"
    check c.observed == "R"

test "Layer 2: H3F3A K28M called for patient_4":
  if not datasetAvailable: skip()
  else:
    let c = find(allCalls, "patient_4_H3F3A", "H3F3A_K28")
    check c.category == "Heterozygous"
    check c.observed == "W"

test "Layer 2 (known limitation, xfail): patient_1 IDH1 R132H is not recoverable from the discrete base call":
  if not datasetAvailable: skip()
  else:
    # During fixture construction the discrete PBAS2 call at patient_1's
    # R132 column was found to be a clean, unambiguous G (matching the
    # WT-flanking context also seen in patient_2), with only a strong
    # secondary T peak (not the expected A) in the raw trace - so no
    # confident nucleotide-level R132H position could be assigned for this
    # sample. This mirrors the paper's own noted R132L tool-limitation
    # (Supplementary Fig. S10, doc §4.4): treated here as a documented
    # open item, not silently dropped. Re-check against the chromatogram
    # (not just the raw peak table) before turning this into a hard
    # assertion.
    skip()

# --- Layer 3: wild-type / negative controls ---------------------------------

test "Layer 3: all no_mutation/ files return WT (Reference) at their labelled gene":
  if not datasetAvailable: skip()
  else:
    let noMutationSamples = toSeq(walkFiles(NoMutationDir / "*.ab1"))
      .mapIt(it.extractFilename.changeFileExt(""))
    check noMutationSamples.len > 0
    for c in allCalls:
      if c.sample in noMutationSamples:
        check c.category == "Reference"

test "Layer 3 (known gap, xfail): H3F3A_LN-229 negative control is absent from the dataset":
  if not datasetAvailable: skip()
  else:
    # Confirmed during dataset reconnaissance: no_mutation/ has 20 files,
    # not the ~19 estimated in the doc, but the 7x3 grid is one short -
    # H3F3A_LN-229_H3F3A_F.ab1 was never provided in the Zenodo archive.
    check not fileExists(NoMutationDir / "H3F3A_LN-229_H3F3A_F.ab1")

# --- Layer 4: edge cases -----------------------------------------------------

test "Layer 4: heterozygous / IUPAC ambiguity calls are reported, not forced homozygous":
  if not datasetAvailable: skip()
  else:
    for (sample, assay, code) in [
      ("TERTp_LN-229_TERTp-9-fwd", "TERTp_C228", "Y"),
      ("patient_2_IDH1", "IDH1_R132", "R"),
      ("patient_3_IDH2", "IDH2_R172", "R"),
      ("patient_4_H3F3A", "H3F3A_K28", "W"),
    ]:
      let c = find(allCalls, sample, assay)
      check c.category == "Heterozygous"
      check c.observed == code

test "Layer 4 (known limitation, xfail): H3F3A G34R (patient_5) is not in the panel":
  if not datasetAvailable: skip()
  else:
    # The patient_5 read is genuinely low-quality (multiple uncalled N
    # bases) in the codon-34 region in every reference orientation tried
    # during fixture construction; no clean discrete or ambiguity-code
    # signal was found, so no G34 target was added to targets.tsv rather
    # than guessing a position. Confirm against the chromatogram before
    # adding a G34 row.
    check not allCalls.anyIt(it.sample == "patient_5_H3F3A" and it.gene == "H3F3A" and it.tag == "G34R")

# --- Layer 5: regression / snapshot ------------------------------------------

test "Layer 5: calls.csv matches the checked-in golden snapshot":
  if not datasetAvailable: skip()
  else:
    doAssert fileExists(GoldenFile), GoldenFile & " missing - see tests/golden/"
    let golden = readFile(GoldenFile).strip()
    let fresh = readFile(WorkDir / "calls.csv").strip()
    check golden == fresh
    # If this fails after an intentional change to abiscreen's calling
    # logic, review the diff manually, then regenerate with:
    #   bin/abiscreen -i datasets/5865470/mutation -i datasets/5865470/no_mutation \
    #     -p tests/fixtures/5865470/targets.tsv -r tests/fixtures/5865470/refs.fa \
    #     -o /tmp/golden_gen --report csv
    #   cp /tmp/golden_gen/calls.csv tests/golden/5865470_calls.csv
