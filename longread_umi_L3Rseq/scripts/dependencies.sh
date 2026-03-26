#!/bin/bash
# DESCRIPTION
#    Paths to dependencies for longread-UMI-pipeline
#
# IMPLEMENTATION
#    author   Søren Karst (sorenkarst@gmail.com)
#             Ryan Ziels (ziels@mail.ubc.ca)
#    license  GNU General Public License
#
# MODIFICATIONS FOR L3Rseq (2026)
#    - Replaced hardcoded 'export USEARCH=usearch' with vsearch
#      (open-source, ARM64-native; usearch is proprietary and no longer needed)
#    - Added compatibility flags (USEARCH_SORTOUT_FLAG, USEARCH_MINSIZE_FLAG,
#      USEARCH_MINSEQLENGTH_FLAG) for vsearch API differences
#    - Skips if USEARCH is already set by the L3Rseq dispatcher
#    Original: https://github.com/SorenKarst/longread_umi

# Program paths

export SEQTK=seqtk
export GNUPARALLEL=parallel
export RACON=racon
export MINIMAP2=minimap2
export GAWK=gawk
export SAMTOOLS=samtools
export BCFTOOLS=bcftools
export CUTADAPT=cutadapt
export PORECHOP_UMI=porechop
export FILTLONG=filtlong
export BWA=bwa
# vsearch (open-source, ARM64-native) replaces usearch (proprietary, x86_64-only).
# Compatibility flags translate the USEARCH variable name used by upstream longread_umi
# scripts into the correct vsearch CLI flags:
#   USEARCH_SORTOUT_FLAG: vsearch sortbysize uses --output (usearch used -fastaout)
#   USEARCH_MINSIZE_FLAG: vsearch cluster_fast has no -minsize (usearch needed it)
#   USEARCH_MINSEQLENGTH_FLAG: vsearch defaults --minseqlength 32, which silently
#     discards short UMIs; we override to 1
# Skip if already set (e.g., by L3Rseq dispatcher)
if [ -z "${USEARCH:-}" ]; then
  if command -v vsearch &>/dev/null; then
    export USEARCH=vsearch
    export USEARCH_SORTOUT_FLAG="--output"
    export USEARCH_MINSIZE_FLAG=""
    export USEARCH_MINSEQLENGTH_FLAG="--minseqlength 1"
  else
    echo "WARNING: vsearch not found on PATH" >&2
    export USEARCH=vsearch
    export USEARCH_SORTOUT_FLAG="--output"
    export USEARCH_MINSIZE_FLAG=""
    export USEARCH_MINSEQLENGTH_FLAG="--minseqlength 1"
  fi
fi

# longread_umi paths
export REF_CURATED=$LONGREAD_UMI_PATH/scripts/zymo-ref-uniq_2019-10-28.fa
export REF_VENDOR=$LONGREAD_UMI_PATH/scripts/zymo-ref-uniq_vendor.fa
export BARCODES=$LONGREAD_UMI_PATH/scripts/barcodes.tsv

# Version dump
longread_umi_version_dump (){
  local OUT=${1:-./longread_umi_version_dump.txt}

  echo "Script start: $(date +%Y-%m-%d-%T)"  >> $OUT
  echo "Software Version:" >> $OUT
  echo "longread_umi - $(git --git-dir ${LONGREAD_UMI_PATH}/.git describe --tag)" >> $OUT
  echo "seqtk - $($SEQTK 2>&1 >/dev/null | grep 'Version')" >> $OUT 
  echo "Parallel - $($GNUPARALLEL --version | head -n 1)" >> $OUT 
  echo "Usearch - $($USEARCH --version)" >> $OUT 
  echo "Racon - $($RACON --version)" >> $OUT
  echo "Minimap2 - $($MINIMAP2 --version)" >> $OUT
  echo "medaka - $(eval $MEDAKA_ENV_START; medaka --version | cut -d" " -f2; eval $MEDAKA_ENV_STOP)"  >> $OUT
  echo "medaka model - ${MEDAKA_MODEL##*/}"  >> $OUT
  echo "Gawk - $($GAWK --version | head -n 1)" >> $OUT 
  echo "Cutadapt - $($CUTADAPT --version | head -n 1)" >> $OUT 
  echo "Porechop - $($PORECHOP_UMI --version) + add UMI adaptors to adaptors.py" >> $OUT 
  echo "Filtlong - $($FILTLONG --version)" >> $OUT
  echo "BWA - $($BWA 2>&1 >/dev/null | grep 'Version')" >> $OUT
  echo "Samtools - $($SAMTOOLS 2>&1 >/dev/null | grep 'Version')" >> $OUT
  echo "Bcftools - $($BCFTOOLS --version | head -n 1)" >> $OUT
}

### Version dump
# source dependencies.sh
# longread_umi_version_dump
