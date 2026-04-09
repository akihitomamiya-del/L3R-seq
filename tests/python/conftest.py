"""Shared pytest fixtures for L3Rseq Python module tests."""

from __future__ import annotations

import pytest


@pytest.fixture
def synthetic_ref() -> str:
    """A 1000bp deterministic synthetic reference sequence (ACGT repeating).

    Useful for walk_correction and call_variants tests where you need a known
    reference background and the actual nucleotide identity doesn't matter.
    """
    return "".join("ACGT"[i % 4] for i in range(1000))


@pytest.fixture
def sample_sam_line() -> str:
    """A minimal tab-separated SAM record (11 fields, no tags).

    QNAME=read1, FLAG=0, RNAME=ref, POS=1, MAPQ=60, CIGAR=10M5S, MRNM=*,
    MPOS=0, ISIZE=0, SEQ=15bp, QUAL=15 'I'.
    """
    return "read1\t0\tref\t1\t60\t10M5S\t*\t0\t0\tACGTACGTACAGGTC\t" + "I" * 15
