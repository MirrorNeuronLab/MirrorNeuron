#!/usr/bin/env bash
set -euo pipefail

TEXT="$(
python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads(Path(os.environ["MIRROR_NEURON_INPUT_FILE"]).read_text())
print(payload["text"], end="")
PY
)"

WORD_COUNT="$(printf '%s\n' "$TEXT" | wc -w | tr -d ' ')"
CHAR_COUNT="$(printf '%s' "$TEXT" | wc -c | tr -d ' ')"

TEXT="$TEXT" WORD_COUNT="$WORD_COUNT" CHAR_COUNT="$CHAR_COUNT" python3 - <<'PY'
import json
import os

print(json.dumps({
    "text": os.environ["TEXT"],
    "word_count": int(os.environ["WORD_COUNT"]),
    "char_count": int(os.environ["CHAR_COUNT"])
}))
PY
