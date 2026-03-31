# tag_summary.awk — Summarize EC/SC/NC/SJ/TL SAM tag distributions.
# Input: SAM records (piped from samtools view).
BEGIN { FS = "\t" }
{
  for (i = 12; i <= NF; i++) {
    if ($i ~ /^EC:i:/) { split($i, a, ":"); ec += a[3]; ecn++ }
    if ($i ~ /^SC:i:/) { split($i, a, ":"); sc += a[3]; scn++ }
    if ($i ~ /^NC:i:/) { split($i, a, ":"); nc += a[3]; ncn++ }
    if ($i ~ /^SJ:Z:S/) sj_s++
    if ($i ~ /^SJ:Z:R/) sj_r++
    if ($i ~ /^SJ:Z:-/) sj_u++
    if ($i ~ /^TL:i:1/) tl++
  }
}
END {
  if (ecn) printf "  EC: total=%d mean=%.1f\n", ec, ec/ecn
  if (scn) printf "  SC: total=%d mean=%.1f\n", sc, sc/scn
  if (ncn) printf "  NC: total=%d mean=%.1f\n", nc, nc/ncn
  if (sj_s + sj_r + sj_u) printf "  SJ: S=%d R=%d -=%d\n", sj_s+0, sj_r+0, sj_u+0
  if (tl) printf "  TL: %d translocations\n", tl
}
