"""Apply the reviewed LiteLLM usage normalization fix while building Core.

LiteLLM 1.100.1 overwrites normalized Usage with OpenAI's BaseModel on a
non-empty-choices usage chunk. Its reducer expects mapping-style membership,
so it then discards the reported counts. Gateway-to-gateway streams use this
shape. Keep this source correction pinned and fail closed on upstream changes.
"""

from hashlib import sha256
from importlib.metadata import distribution


VERSION = "1.100.1"
SOURCE = "litellm/litellm_core_utils/streaming_handler.py"
UPSTREAM_SHA256 = "eb1958a1f3c2a615a7a2a10b9ec67d2d8b60c3442e7530171a6aed781f53c8f4"
ORIGINAL = """            if hasattr(chunk, "usage") and chunk.usage is not None:
                model_response.usage = chunk.usage
"""
CORRECTED = """            if hasattr(chunk, "usage") and chunk.usage is not None:
                if isinstance(chunk.usage, BaseModel) and not isinstance(chunk.usage, Usage):
                    model_response.usage = Usage(**chunk.usage.model_dump())
                else:
                    model_response.usage = chunk.usage
"""


def corrected_source(source: str) -> str:
    if sha256(source.encode()).hexdigest() != UPSTREAM_SHA256:
        raise RuntimeError(
            "LiteLLM stream source changed; review the usage fix before building"
        )
    if source.count(ORIGINAL) != 1:
        raise RuntimeError("LiteLLM usage normalization target is not unique")
    result = source.replace(ORIGINAL, CORRECTED, 1)
    compile(result, SOURCE, "exec")
    return result


def main() -> None:
    package = distribution("litellm")
    if package.version != VERSION:
        raise RuntimeError(f"LiteLLM {VERSION} is required for the reviewed usage fix")
    path = package.locate_file(SOURCE)
    path.write_text(corrected_source(path.read_text()))
    print(f"Applied LiteLLM {VERSION} provider usage normalization")


if __name__ == "__main__":
    main()
