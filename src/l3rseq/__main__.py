"""Enable ``python -m l3rseq`` as a shortcut for ``python -m l3rseq.tail_correct``.

Step 09 is the only Python-backed step right now, so ``python -m l3rseq``
invokes it directly. When other steps are ported (step 11 gene counting,
step 10 CSV export, etc.), this file should become a dispatcher that
routes by subcommand.
"""

from __future__ import annotations

import sys

from l3rseq.tail_correct import main

if __name__ == "__main__":
    sys.exit(main())
