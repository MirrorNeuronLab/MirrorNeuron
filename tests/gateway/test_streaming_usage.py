"""Exercise the installed gateway library, including its real HTTP stream path."""

import asyncio
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

import litellm
from litellm.main import ChunkProcessor
from litellm.types.utils import ModelResponseStream, Usage
from openai import AsyncOpenAI


PROVIDER_USAGE = {
    "prompt_tokens": 24,
    "completion_tokens": 120,
    "total_tokens": 144,
    "completion_tokens_details": {"reasoning_tokens": 116},
    "prompt_tokens_details": {"cached_tokens": 4},
}


class ForwardedUsageTests(unittest.IsolatedAsyncioTestCase):
    async def check_stream(
        self, *, empty_choices: bool, reasoning: bool, streaming: bool = True
    ) -> None:
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                request = json.loads(
                    self.rfile.read(int(self.headers["Content-Length"]))
                )
                requests.append(request)
                self.send_response(200)
                if not request.get("stream"):
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(
                        json.dumps(
                            {
                                "id": "test-nonstream",
                                "object": "chat.completion",
                                "created": 1,
                                "model": request["model"],
                                "choices": [
                                    {
                                        "index": 0,
                                        "message": {
                                            "role": "assistant",
                                            "content": "4",
                                        },
                                        "finish_reason": "stop",
                                    }
                                ],
                                "usage": PROVIDER_USAGE,
                            }
                        ).encode()
                    )
                    return
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                base = {
                    "id": "test-forwarded-stream",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": request["model"],
                }
                parts = []
                if reasoning:
                    parts.append(
                        {
                            "choices": [
                                {
                                    "index": 0,
                                    "delta": {
                                        "role": "assistant",
                                        "reasoning_content": "Reasoning.",
                                    },
                                    "finish_reason": None,
                                }
                            ]
                        }
                    )
                parts.extend(
                    [
                        {
                            "choices": [
                                {
                                    "index": 0,
                                    "delta": {"content": "4"},
                                    "finish_reason": None,
                                }
                            ]
                        },
                        {
                            "choices": [
                                {"index": 0, "delta": {}, "finish_reason": "stop"}
                            ]
                        },
                        {
                            "choices": []
                            if empty_choices
                            else [{"index": 0, "delta": {}, "finish_reason": None}],
                            "usage": PROVIDER_USAGE,
                        },
                    ]
                )
                for part in parts:
                    self.wfile.write(
                        ("data: " + json.dumps({**base, **part}) + "\n\n").encode()
                    )
                    self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}/v1"
            async with AsyncOpenAI(api_key="not-needed", base_url=base) as client:
                stream = await litellm.acompletion(
                    model="openai/__mn_owner__/test/model",
                    api_base=base,
                    api_key="not-needed",
                    client=client,
                    messages=[{"role": "user", "content": "Reply with the number 4."}],
                    **(
                        {"stream": True, "stream_options": {"include_usage": True}}
                        if streaming
                        else {}
                    ),
                )
                usage = (
                    [
                        chunk.usage
                        async for chunk in stream
                        if getattr(chunk, "usage", None)
                    ]
                    if streaming
                    else [stream.usage]
                )
            self.assertEqual(len(requests), 1)
            if streaming:
                self.assertEqual(requests[0]["stream_options"], {"include_usage": True})
            self.assertEqual(len(usage), 1)
            self.assertEqual(usage[0].prompt_tokens, 24)
            self.assertEqual(usage[0].completion_tokens, 120)
            self.assertEqual(usage[0].total_tokens, 144)
            self.assertEqual(usage[0].completion_tokens_details.reasoning_tokens, 116)
            self.assertEqual(usage[0].prompt_tokens_details.cached_tokens, 4)
            if streaming:
                self.assertTrue(
                    all(
                        isinstance(c.usage, Usage)
                        for c in stream.chunks
                        if getattr(c, "usage", None)
                    )
                )
        finally:
            await asyncio.to_thread(server.shutdown)
            server.server_close()
            thread.join()

    async def test_forwarded_reasoning_usage_with_nonempty_choices(self):
        await self.check_stream(empty_choices=False, reasoning=True)

    async def test_forwarded_text_usage_with_nonempty_choices(self):
        await self.check_stream(empty_choices=False, reasoning=False)

    async def test_native_usage_with_empty_choices(self):
        await self.check_stream(empty_choices=True, reasoning=True)

    async def test_nonstream_provider_usage_is_unchanged(self):
        await self.check_stream(empty_choices=False, reasoning=True, streaming=False)


class UsageReducerTests(unittest.TestCase):
    def test_provider_counts_require_no_retokenization(self):
        # The corrected stream boundary hands the reducer LiteLLM Usage.
        chunk = ModelResponseStream(usage=Usage(**PROVIDER_USAGE))
        processor = ChunkProcessor([chunk], [{"role": "user", "content": "hello"}])
        with patch(
            "litellm.litellm_core_utils.streaming_chunk_builder_utils.token_counter",
            side_effect=AssertionError("provider counts must not be re-estimated"),
        ):
            usage = processor.calculate_usage(
                [chunk],
                model="test-model",
                completion_output="4",
                reasoning_tokens=116,
            )
        self.assertEqual(
            (usage.prompt_tokens, usage.completion_tokens, usage.total_tokens),
            (24, 120, 144),
        )


if __name__ == "__main__":
    unittest.main()
