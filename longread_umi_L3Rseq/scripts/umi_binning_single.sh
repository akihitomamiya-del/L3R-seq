#!/bin/bash

# DESCRIPTION
#    Script for binning long reads based on a single UMI. Part of
#    longread_umi. Designed for 3' RNA-seq libraries with one UMI
#    within the adapter structure.
#
#    Uses cutadapt --revcomp for orientation-independent UMI extraction,
#    usearch for clustering, and BWA for read-to-bin assignment.
#
# IMPLEMENTATION
#    author   Based on umi_binning.sh by Søren Karst and Ryan Ziels
#             (https://github.com/SorenKarst/longread_umi)
#             New script for L3Rseq (2026) — not part of the original project
#    license  GNU General Public License

USAGE="
-- longread_umi umi_binning_single: Single-UMI detection and read binning.
   For libraries with a single UMI flanked by known adapter sequences.
   Uses cutadapt --revcomp for orientation-independent UMI extraction.

usage: $(basename "$0" .sh) [-h] (-d file -o dir -f string -r string)
(-l value -n value -t value)

where:
    -h  Show this help text.
    -d  Reads in fastq format (pre-trimmed/filtered).
    -o  Output directory.
    -f  5' UMI flanking sequence (e.g., CTGAC).
    -r  3' UMI flanking sequence (e.g., TGGAATTCTCGGGTGCCAAGGC).
    -l  UMI length [Default: 15].
    -n  Minimum bin size [Default: 4]. Bins below this are moved
        to bins_small/ for inspection.
    -t  Number of threads [Default: all available].
"

### Terminal Arguments ---------------------------------------------------------

# Import user arguments
while getopts ':hd:o:f:r:l:n:t:' OPTION; do
  case $OPTION in
    h) echo "$USAGE"; exit 1;;
    d) READ_IN=$OPTARG;;
    o) OUT_DIR=$OPTARG;;
    f) FLANK5=$OPTARG;;
    r) FLANK3=$OPTARG;;
    l) UMI_LENGTH=$OPTARG;;
    n) MIN_BIN_SIZE=$OPTARG;;
    t) THREADS=$OPTARG;;
    :) printf "missing argument for -%s\n" "$OPTARG" >&2; exit 1;;
    \?) printf "invalid option for -%s\n" "$OPTARG" >&2; exit 1;;
  esac
done

# Check missing arguments
MISSING="is missing but required. Exiting."
if [ -z ${READ_IN+x} ]; then echo "-d $MISSING"; echo ""; echo "$USAGE"; exit 1; fi
if [ -z ${OUT_DIR+x} ]; then echo "-o $MISSING"; echo ""; echo "$USAGE"; exit 1; fi
if [ -z ${FLANK5+x} ]; then echo "-f $MISSING"; echo ""; echo "$USAGE"; exit 1; fi
if [ -z ${FLANK3+x} ]; then echo "-r $MISSING"; echo ""; echo "$USAGE"; exit 1; fi

# Defaults
if [ -z ${UMI_LENGTH+x} ]; then UMI_LENGTH=15; fi
if [ -z ${MIN_BIN_SIZE+x} ]; then MIN_BIN_SIZE=4; fi
if [ -z ${THREADS+x} ]; then THREADS=$(nproc 2>/dev/null || echo 1); fi

### Source dependencies --------------------------------------------------------
. $LONGREAD_UMI_PATH/scripts/dependencies.sh

### Setup output directories ---------------------------------------------------
mkdir -p $OUT_DIR
TRIM_DIR=$OUT_DIR/trim
UMI_DIR=$OUT_DIR/umi_ref
BINNING_DIR=$OUT_DIR/read_binning
mkdir -p $TRIM_DIR $UMI_DIR $BINNING_DIR $BINNING_DIR/bins

# Symlink input reads for downstream compatibility
ln -sf "$(cd "$(dirname "$READ_IN")" && pwd -P)/$(basename "$READ_IN")" "$TRIM_DIR/reads_tf.fq"

### Extract UMIs with cutadapt -------------------------------------------------
echo "[umi_binning_single] Extracting UMIs with cutadapt --revcomp..."

# Reverse the adapter search order: use reverse-complements so the long,
# specific FLANK3_RC (22bp) is searched first as the 5' adapter in -g.
# This avoids spurious matches from the short FLANK5 (5bp).
# With --revcomp, cutadapt handles both read orientations.
FLANK3_RC=$(echo "$FLANK3" | tr 'ACGTacgt' 'TGCAtgca' | rev)
FLANK5_RC=$(echo "$FLANK5" | tr 'ACGTacgt' 'TGCAtgca' | rev)

$CUTADAPT -j $THREADS -e 0.2 -O 11 \
  -m $UMI_LENGTH -M $UMI_LENGTH \
  --discard-untrimmed \
  --revcomp \
  -g "${FLANK3_RC}...${FLANK5_RC}" \
  -o $UMI_DIR/umi_extracted.fq \
  $TRIM_DIR/reads_tf.fq > $UMI_DIR/umi_trim.log 2>&1

# Check output
if [ ! -s "$UMI_DIR/umi_extracted.fq" ]; then
  echo "[umi_binning_single] ERROR: No UMIs extracted. Check flanking sequences." >&2
  exit 1
fi

# Convert extracted UMIs to FASTA (keep read names)
$GAWK '
  NR%4==1 {print ">" substr($1, 2)}
  NR%4==2 {print $0}
' $UMI_DIR/umi_extracted.fq > $UMI_DIR/umi.fa

UMI_COUNT=$(grep -c '^>' $UMI_DIR/umi.fa)
echo "[umi_binning_single] $UMI_COUNT UMIs extracted."

### Cluster UMIs ---------------------------------------------------------------
echo "[umi_binning_single] Clustering UMIs..."

# Deduplicate (without -relabel; we sort and relabel deterministically below)
$USEARCH -fastx_uniques $UMI_DIR/umi.fa \
  -fastaout $UMI_DIR/umi_u_unsorted.fa \
  -sizeout -minuniquesize 1 -strand both

# Sort deterministically: descending size (primary), lexicographic sequence
# (secondary). This ensures identical umi1, umi2, ... labels regardless of
# which engine is used (vsearch and usearch have different hash-table iteration
# order in fastx_uniques, causing non-deterministic output within same-size groups).
$GAWK '
  /^>/ { if (name) { seqs[name] = seq }; name = $0; seq = ""; next }
  { seq = seq $0 }
  END {
    if (name) seqs[name] = seq
    for (n in seqs) {
      match(n, /size=([0-9]+)/, a)
      print a[1]+0 "\t" seqs[n] "\t" n
    }
  }
' $UMI_DIR/umi_u_unsorted.fa | sort -k1,1nr -k2,2 | \
$GAWK -v pre="umi" '
  { printf ">%s%d;size=%d\n%s\n", pre, NR, $1, $2 }
' > $UMI_DIR/umi_u.fa

rm -f $UMI_DIR/umi_u_unsorted.fa

# Cluster at 90% identity (allows 1bp mismatch on 15bp UMIs).
# Kept as a safety net: on some datasets this merges near-identical UMIs
# that deduplication missed. Consistent with the 1-mismatch tolerance
# used in the BWA bin assignment stage.
$USEARCH -cluster_fast $UMI_DIR/umi_u.fa \
  -id 0.90 \
  -centroids $UMI_DIR/umi_c.fa \
  -uc $UMI_DIR/umi_c.txt \
  -sizein -sizeout -strand both $USEARCH_MINSIZE_FLAG $USEARCH_MINSEQLENGTH_FLAG

CLUSTER_COUNT=$(grep -c '^>' $UMI_DIR/umi_c.fa)
echo "[umi_binning_single] $CLUSTER_COUNT UMI clusters after dedup + clustering."

### Write cluster size statistics ----------------------------------------------
echo "[umi_binning_single] Writing cluster statistics..."

$GAWK '
  /^>/ {
    match($0, /size=([0-9]+)/, a)
    size = a[1] + 0
    sizes[NR] = size
    count[size]++
    total++
    sum += size
    if (size == 1) s1++
  }
  END {
    # Summary stats file
    print "stage\tmetric\tvalue" > BD "/umi_cluster_stats.tsv"
    print "extract\ttotal_reads\t" TR > BD "/umi_cluster_stats.tsv"
    print "extract\tumis_extracted\t" UE > BD "/umi_cluster_stats.tsv"
    print "dedup\tunique_umis\t" total > BD "/umi_cluster_stats.tsv"
    print "dedup\tsingleton_umis\t" s1+0 > BD "/umi_cluster_stats.tsv"
    print "dedup\tnon_singleton_umis\t" total-(s1+0) > BD "/umi_cluster_stats.tsv"
    print "dedup\tmax_cluster_size\t" max_s > BD "/umi_cluster_stats.tsv"
    print "dedup\tmean_cluster_size\t" sprintf("%.1f", sum/total) > BD "/umi_cluster_stats.tsv"

    # Full size distribution
    print "cluster_size\tcount" > BD "/umi_cluster_size_dist.tsv"
    for (s = 1; s <= max_s; s++) {
      if (count[s] > 0) print s "\t" count[s] > BD "/umi_cluster_size_dist.tsv"
    }
  }
  BEGIN {max_s = 0}
  /^>/ {
    match($0, /size=([0-9]+)/, a)
    if (a[1]+0 > max_s) max_s = a[1]+0
  }
' TR="$UMI_COUNT" UE="$UMI_COUNT" BD="$BINNING_DIR" $UMI_DIR/umi_c.fa

# Build UMI references: remove singletons (size=1).
# Singletons are UMIs seen in only 1 read — likely sequencing errors.
# Removing them from the reference prevents them from acting as false
# attractors during BWA mapping, allowing those reads to join real bins.
$GAWK '
  /^>/ {
    match($0, /size=([0-9]+)/, a)
    keep = (a[1] + 0 >= 2)
  }
  keep { print }
' $UMI_DIR/umi_c.fa > $UMI_DIR/umi_ref.fa

if [ ! -s "$UMI_DIR/umi_ref.fa" ]; then
  echo "[umi_binning_single] ERROR: No UMI clusters with size >= 2." >&2
  exit 1
fi

REF_COUNT=$(grep -c '^>' $UMI_DIR/umi_ref.fa)
echo "[umi_binning_single] $REF_COUNT UMI references after singleton removal."

### Bin reads by UMI mapping ---------------------------------------------------
echo "[umi_binning_single] Mapping UMI references to extracted UMIs..."

# Index per-read extracted UMIs (one UMI per read, named by read)
$BWA index $UMI_DIR/umi.fa

# Map UMI references against extracted UMIs
# -n 2: search radius of 2 mismatches (broad search, ensures reads whose
#        singleton reference was removed can find the nearest real reference)
# -N: report all hits (needed for best-match assignment in gawk)
$BWA aln $UMI_DIR/umi.fa $UMI_DIR/umi_ref.fa \
  -n 2 -t $THREADS -N > $BINNING_DIR/umi_map.sai
$BWA samse -n 10000000 $UMI_DIR/umi.fa \
  $BINNING_DIR/umi_map.sai $UMI_DIR/umi_ref.fa | \
  $SAMTOOLS view -F 4 - > $BINNING_DIR/umi_map.sam

### Filter and assign reads to bins --------------------------------------------
# NM <= 1: strict assignment (max 1 mismatch accepted).
# BWA -n 2 casts a wide search net, but only high-quality matches are kept.
echo "[umi_binning_single] Filtering UMI matches (max 1 mismatch, best-match)..."

$GAWK \
  -v BD="$BINNING_DIR" \
  '
  {
    # Reset per-record
    perr = ""
    delete shits

    # Extract NM (edit distance) and XA (secondary hits) from SAM optional fields
    for (i = 12; i <= NF; i++) {
      if ($i ~ /^NM:i:/) { sub("NM:i:", "", $i); perr = $i }
      if ($i ~ /^XA:Z:/) { sub("XA:Z:", "", $i); split($i, shits, ";") }
    }

    # Primary hit: $1=UMI ref name (query), $3=read name (target)
    if (perr + 0 <= 1) {
      if (!($3 in match_err) || match_err[$3] > perr + 0) {
        match_umi[$3] = $1
        match_err[$3] = perr + 0
      }
    }

    # Secondary hits from XA tag (format: read_name,pos,CIGAR,NM;...)
    for (i in shits) {
      split(shits[i], tmp, ",")
      if (tmp[1] != "" && tmp[4] + 0 <= 1) {
        if (!(tmp[1] in match_err) || match_err[tmp[1]] > tmp[4] + 0) {
          match_umi[tmp[1]] = $1
          match_err[tmp[1]] = tmp[4] + 0
        }
      }
    }
  }
  END {
    # Count reads per bin
    for (read in match_umi) {
      umi_n[match_umi[read]]++
    }

    # Print per-bin read counts
    print "umi_name\tread_count" > BD "/umi_binning_stats.txt"
    for (u in umi_n) {
      print u "\t" umi_n[u] > BD "/umi_binning_stats.txt"
    }

    # Print read-to-bin assignments (3-column TSV)
    for (read in match_umi) {
      print match_umi[read], read, match_err[read]
    }
  }
' $BINNING_DIR/umi_map.sam > $BINNING_DIR/umi_bin_map.txt

ASSIGNED=$(wc -l < $BINNING_DIR/umi_bin_map.txt)
echo "[umi_binning_single] $ASSIGNED reads assigned to bins."

### Extract binned reads -------------------------------------------------------
echo "[umi_binning_single] Extracting binned reads..."

umi_binning() {
  # Input
  local UMIMAP=$1
  local OUT=$2

  # Binning — adapted from umi_binning.sh (removed "./" prefix for absolute paths)
  $GAWK -v out="$OUT" '
    BEGIN {g=1; outsub=out"/"g; system("mkdir -p \047" outsub "\047");}
    NR==FNR {
      # Get read name (strip ;size=N suffix)
      sub(";.*", "", $1);
      # Associate read name and umi match
      bin[$2]=$1;
      # Assign umi to a folder group if it has none
      if (foldergrp[$1] == ""){
        j++;
        if (j <= 4000){
          foldergrp[$1]=g;
        } else {
          j = 0;
          g++;
          foldergrp[$1]=g;
          outsub=out"/"g;
          system("mkdir -p \047" outsub "\047");
        }
      }
      next;
    }
    FNR%4==1 {
      read=substr($1,2);
      bin_tmp=bin[read]
      if ( bin_tmp != "" ){
        binfile=out"/"foldergrp[bin_tmp]"/"bin_tmp"bins.fastq";
        print > binfile;
        getline; print > binfile;
        getline; print > binfile;
        getline; print > binfile;
      }
    }
  ' $UMIMAP -
}

export -f umi_binning

cat $TRIM_DIR/reads_tf.fq | \
  $GNUPARALLEL \
    --env umi_binning \
    -L4 \
    -j $THREADS \
    --block 300M \
    --pipe \
  "mkdir -p $BINNING_DIR/bins/job{#}; \
  cat | umi_binning $BINNING_DIR/umi_bin_map.txt \
  $BINNING_DIR/bins/job{#}"

### Aggregate bins -------------------------------------------------------------

aggregate_bins() {
  # Input
  local IN=$1
  local OUTDIR=$2
  local OUTNAME=$3
  local JOB=$4

  # Determine output folder (4000 bins per subdirectory)
  local BIN=$(( ($JOB - 1)/4000 ))
  mkdir -p $OUTDIR/$BIN

  # Aggregate data from all job directories
  cat $IN > $OUTDIR/$BIN/$OUTNAME
}

export -f aggregate_bins

find $BINNING_DIR/bins/*/*/ -name "*bins.fastq" | sed 's|.*/||' | \
  sort | \
  uniq | \
  $GNUPARALLEL \
    --env aggregate_bins \
    -j $THREADS \
    "aggregate_bins '$BINNING_DIR/bins/*/*/'{/} \
    $BINNING_DIR/bins {/} {#}"

# Clean up job directories
rm -r $BINNING_DIR/bins/job*

### Bin size filtering ---------------------------------------------------------
echo "[umi_binning_single] Filtering bins by minimum size ($MIN_BIN_SIZE reads)..."

mkdir -p $BINNING_DIR/bins_small

# Count reads per bin, move small bins, and record the distribution
echo "bin_name	reads	status" > $BINNING_DIR/umi_bin_size_dist.tsv

for bin_dir in $BINNING_DIR/bins/*/; do
  [ -d "$bin_dir" ] || continue
  subdir=$(basename "$bin_dir")

  for fq in "$bin_dir"/*bins.fastq; do
    [ -f "$fq" ] || continue
    bname=$(basename "$fq" .fastq)
    nreads=$(( $(wc -l < "$fq") / 4 ))
    if [ "$nreads" -lt "$MIN_BIN_SIZE" ]; then
      echo "${bname}	${nreads}	small" >> $BINNING_DIR/umi_bin_size_dist.tsv
      mkdir -p "$BINNING_DIR/bins_small/$subdir"
      mv "$fq" "$BINNING_DIR/bins_small/$subdir/"
    else
      echo "${bname}	${nreads}	kept" >> $BINNING_DIR/umi_bin_size_dist.tsv
    fi
  done
done

# Final summary stats
KEPT_BINS=$(grep -c 'kept$' $BINNING_DIR/umi_bin_size_dist.tsv)
SMALL_BINS=$(grep -c 'small$' $BINNING_DIR/umi_bin_size_dist.tsv)
TOTAL_KEPT_READS=$(awk -F'\t' '$3=="kept"{s+=$2} END{print s+0}' $BINNING_DIR/umi_bin_size_dist.tsv)

# Append bin-level stats to the cluster stats file
printf "bins\ttotal_bins\t%d\n" "$((KEPT_BINS + SMALL_BINS))" >> $BINNING_DIR/umi_cluster_stats.tsv
printf "bins\tkept_bins\t%d\n" "$KEPT_BINS" >> $BINNING_DIR/umi_cluster_stats.tsv
printf "bins\tsmall_bins\t%d\n" "$SMALL_BINS" >> $BINNING_DIR/umi_cluster_stats.tsv
printf "bins\treads_in_kept_bins\t%d\n" "$TOTAL_KEPT_READS" >> $BINNING_DIR/umi_cluster_stats.tsv
printf "bins\treads_assigned\t%d\n" "$ASSIGNED" >> $BINNING_DIR/umi_cluster_stats.tsv
printf "bins\tmin_bin_size\t%d\n" "$MIN_BIN_SIZE" >> $BINNING_DIR/umi_cluster_stats.tsv

echo "[umi_binning_single] $KEPT_BINS bins kept (>= $MIN_BIN_SIZE reads), $SMALL_BINS bins moved to bins_small/."
echo "[umi_binning_single] $TOTAL_KEPT_READS reads in kept bins."
echo "[umi_binning_single] Stats: $BINNING_DIR/umi_cluster_stats.tsv"
echo "[umi_binning_single] Cluster size distribution: $BINNING_DIR/umi_cluster_size_dist.tsv"
echo "[umi_binning_single] Bin size distribution: $BINNING_DIR/umi_bin_size_dist.tsv"
echo "[umi_binning_single] Done. Output in $OUT_DIR/"

exit 0
