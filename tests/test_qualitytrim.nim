import std/unittest
import ../src/qualitytrim

suite "trimSequence Tests":

  test "High quality sequence should not be trimmed":
    let seq = "ACGTACGTACGT"
    let qual = @[40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40]
    let trimmed = trimSequence(seq, qual, 4, 20)
    check trimmed.seq == seq
    check trimmed.qual == qual

  test "Sequence shorter than window should not be trimmed":
    let seq = "ACG"
    let qual = @[10, 10, 10]
    let trimmed = trimSequence(seq, qual, 4, 20)
    check trimmed.seq == seq
    check trimmed.qual == qual

  test "Qualities shorter than window should not be trimmed":
    let seq = "ACGTACGT"
    let qual = @[10, 10]
    let trimmed = trimSequence(seq, qual, 4, 20)
    check trimmed.seq == seq
    check trimmed.qual == qual

  test "Low quality at start should be trimmed":
    # qual: [5,5,5,5,5,40,40,40,40,40,40,40], window=4, threshold=20
    # Start scan: i=0..2 below threshold, i=3: avg(5,5,40,40)=22.5 >= 20 → startPos=3
    # End scan: i=8: avg(40,40,40,40)=40 >= 20 → endPos=12
    let seq = "AAAAACGTACGT"
    let qual = @[5, 5, 5, 5, 5, 40, 40, 40, 40, 40, 40, 40]
    let trimmed = trimSequence(seq, qual, 4, 20)
    check trimmed.seq == "AACGTACGT"
    check trimmed.qual == @[5, 5, 40, 40, 40, 40, 40, 40, 40]

  test "Low quality at end should be trimmed":
    # qual: [40,40,40,40,40,40,40,40,5,5,5,5], window=4, threshold=20
    # Start scan: i=0: avg(40,40,40,40)=40 >= 20 → startPos=0
    # End scan: i=7: avg(40,5,5,5)=13.75 < 20; i=6: avg(40,40,5,5)=22.5 >= 20 → endPos=10
    let seq = "ACGTACGTAAAA"
    let qual = @[40, 40, 40, 40, 40, 40, 40, 40, 5, 5, 5, 5]
    let trimmed = trimSequence(seq, qual, 4, 20)
    check trimmed.seq == "ACGTACGTAA"
    check trimmed.qual == @[40, 40, 40, 40, 40, 40, 40, 40, 5, 5]

  test "Low quality at both ends should be trimmed":
    # qual: [5,5,5,5,40,40,40,40,40,40,40,5,5,5,5], window=4, threshold=20
    # Start scan: i=0: avg=5, i=1: avg=13.75, i=2: avg(5,5,40,40)=22.5 >= 20 → startPos=2
    # End scan: i=11: avg=5, i=10: avg=13.75, i=9: avg(40,40,5,5)=22.5 >= 20 → endPos=13
    let seq = "AAAACGTACGTAAAA"
    let qual = @[5, 5, 5, 5, 40, 40, 40, 40, 40, 40, 40, 5, 5, 5, 5]
    let trimmed = trimSequence(seq, qual, 4, 20)
    check trimmed.seq == "AACGTACGTAA"
    check trimmed.qual == @[5, 5, 40, 40, 40, 40, 40, 40, 40, 5, 5]

  test "Entire sequence below threshold should return empty":
    let seq = "ACGTACGT"
    let qual = @[5, 5, 5, 5, 5, 5, 5, 5]
    let trimmed = trimSequence(seq, qual, 4, 20)
    check trimmed.seq == ""
    check trimmed.qual == newSeq[int](0)

  test "Single high quality base surrounded by low quality":
    # No window of 4 consecutive bases averages >= 20, so entire sequence is trimmed
    let seq = "AAAACAAAA"
    let qual = @[5, 5, 5, 5, 40, 5, 5, 5, 5]
    let trimmed = trimSequence(seq, qual, 4, 20)
    check trimmed.seq == ""
    check trimmed.qual == newSeq[int](0)

  test "Uniform quality exactly at threshold":
    let seq = "ACGTACGT"
    let qual = @[20, 20, 20, 20, 20, 20, 20, 20]
    let trimmed = trimSequence(seq, qual, 4, 20)
    check trimmed.seq == seq
    check trimmed.qual == qual

  test "Window size of 1 trims individual bases":
    let seq = "AACGTAA"
    let qual = @[5, 5, 40, 40, 40, 5, 5]
    let trimmed = trimSequence(seq, qual, 1, 20)
    check trimmed.seq == "CGT"
    check trimmed.qual == @[40, 40, 40]

