# cigar_summary.awk — Summarize soft-clip distribution from CIGARs.
# Input: SAM records (piped from samtools view).
BEGIN { FS = "\t" }
{
  c = $6
  if (match(c, /^[0-9]+S/)) left_s++
  if (match(c, /[0-9]+S$/)) {
    s = substr(c, RSTART)
    gsub(/S/, "", s)
    if (s + 0 > 5) right_s++
    tot_clip += s + 0
  }
  n++
}
END {
  printf "  CIGARs: %d reads, %d with right-clip >5bp", n, right_s+0
  if (right_s) printf " (avg %dbp)", tot_clip / right_s
  printf "\n"
}
