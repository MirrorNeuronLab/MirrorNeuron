import json
import os
from pathlib import Path

payload = json.loads(Path(os.environ["MIRROR_NEURON_INPUT_FILE"]).read_text())
shell_metrics = json.loads(payload["sandbox"]["stdout"])
source = payload["input"]

result = {
    "request_id": source["request_id"],
    "headline": f"{source['label']}: {shell_metrics['word_count']} words, {shell_metrics['char_count']} chars",
    "explanation": "BEAM orchestrated the flow and OpenShell executed the worker payload folders inside isolated sandboxes.",
    "text_preview": shell_metrics["text"][:40]
}

print(json.dumps(result))
