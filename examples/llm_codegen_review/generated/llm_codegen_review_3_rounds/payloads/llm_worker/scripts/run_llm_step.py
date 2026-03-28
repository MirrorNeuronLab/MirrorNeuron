#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def load_message() -> dict:
    return json.loads(Path(os.environ["MIRROR_NEURON_MESSAGE_FILE"]).read_text())


def extract_payload(message: dict) -> dict:
    body = message.get("body") or {}

    if isinstance(body, dict) and isinstance(body.get("sandbox"), dict):
      stdout = (body.get("sandbox", {}).get("stdout") or "").strip()
      if stdout:
          return json.loads(stdout)

    return body


def gemini_model() -> str:
    return os.environ.get("LLM_MODEL", "gemini-2.5-flash-lite")


def gemini_api_key() -> str:
    api_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY or GOOGLE_API_KEY is required for LLM workers")
    return api_key


def call_gemini(system_instruction: str, prompt: str) -> dict:
    request_body = {
        "system_instruction": {"parts": [{"text": system_instruction}]},
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "responseMimeType": "application/json",
            "temperature": 0.2,
        },
    }

    endpoint = f"https://generativelanguage.googleapis.com/v1beta/models/{gemini_model()}:generateContent"

    try:
        response = subprocess.run(
            [
                "curl",
                "-sS",
                endpoint,
                "-H",
                f"x-goog-api-key: {gemini_api_key()}",
                "-H",
                "Content-Type: application/json",
                "-X",
                "POST",
                "-d",
                json.dumps(request_body),
            ],
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
    except FileNotFoundError as error:
        raise RuntimeError("curl is required for the LLM worker but was not found on PATH") from error

    if response.returncode != 0:
        raise RuntimeError(
            f"Gemini API request failed via curl: exit={response.returncode} stderr={response.stderr.strip()}"
        )

    raw = json.loads(response.stdout)

    text = []
    for candidate in raw.get("candidates", []):
        content = candidate.get("content", {})
        for part in content.get("parts", []):
            if "text" in part:
                text.append(part["text"])

    if not text:
        raise RuntimeError(f"Gemini response did not contain text: {json.dumps(raw)}")

    return parse_json_blob("\n".join(text))


def parse_json_blob(raw_text: str) -> dict:
    text = raw_text.strip()

    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z0-9_-]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text)
        text = text.strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", text, re.DOTALL)
        if not match:
            raise
        return json.loads(match.group(0))


def codegen_prompt(task: dict, round_number: int, prior_code: str | None, review: dict | None) -> tuple[str, str]:
    system_instruction = (
        "You are a careful senior Python engineer. Return only a JSON object with keys "
        "file_name, summary, changes, and code. The code field must be a complete Python source file "
        "as a plain JSON string, with no markdown fences."
    )

    review_json = json.dumps(review, indent=2) if review else "null"
    prior_code_text = prior_code or "<none yet>"
    prompt = f"""
Task:
{json.dumps(task, indent=2)}

Round: {round_number}

Prior code:
{prior_code_text}

Latest review:
{review_json}

Write or revise the Python solution so it satisfies the task and validation expectations.
Use only the Python standard library.
Return JSON with:
- file_name: output file name
- summary: one short sentence
- changes: list of short bullets describing what changed this round
- code: the full Python source code
""".strip()
    return system_instruction, prompt


def review_prompt(candidate: dict, round_number: int) -> tuple[str, str]:
    system_instruction = (
        "You are a strict code reviewer. Return only a JSON object with keys summary, strengths, "
        "improvement_suggestions, and risk_flags. Keep suggestions actionable and concrete."
    )
    prompt = f"""
Task:
{json.dumps(candidate["task"], indent=2)}

Review round: {round_number}

Candidate file name:
{candidate["file_name"]}

Candidate code:
{candidate["code"]}

Review the code against the task. Focus on correctness, CLI behavior, edge cases, and maintainability.
Return JSON with:
- summary: one short sentence
- strengths: list of 2-4 strengths
- improvement_suggestions: list of 2-5 concrete changes
- risk_flags: list of notable residual risks, possibly empty
""".strip()
    return system_instruction, prompt


def run_codegen(payload: dict, round_number: int) -> dict:
    if payload.get("kind") == "code_review":
        task = payload["task"]
        prior_code = payload["candidate_code"]
        review = payload
        history = payload.get("history", [])
    else:
        task = payload
        prior_code = None
        review = None
        history = []

    system_instruction, prompt = codegen_prompt(task, round_number, prior_code, review)
    response = call_gemini(system_instruction, prompt)

    return {
        "kind": "code_generation",
        "round": round_number,
        "task": task,
        "file_name": response.get("file_name", "inventory_report.py"),
        "summary": response.get("summary", f"Generated round {round_number} code."),
        "changes": response.get("changes", []),
        "code": response["code"],
        "history": history
        + [
            {
                "stage": "codegen",
                "round": round_number,
                "summary": response.get("summary", ""),
                "changes": response.get("changes", []),
            }
        ],
    }


def run_review(payload: dict, round_number: int) -> dict:
    if payload.get("kind") != "code_generation":
        raise RuntimeError(f"review step expected code_generation payload, got {payload.get('kind')}")

    system_instruction, prompt = review_prompt(payload, round_number)
    response = call_gemini(system_instruction, prompt)

    return {
        "kind": "code_review",
        "round": round_number,
        "task": payload["task"],
        "file_name": payload["file_name"],
        "candidate_code": payload["code"],
        "summary": response.get("summary", f"Reviewed round {round_number} code."),
        "strengths": response.get("strengths", []),
        "improvement_suggestions": response.get("improvement_suggestions", []),
        "risk_flags": response.get("risk_flags", []),
        "history": payload.get("history", [])
        + [
            {
                "stage": "review",
                "round": round_number,
                "summary": response.get("summary", ""),
                "improvement_suggestions": response.get("improvement_suggestions", []),
                "risk_flags": response.get("risk_flags", []),
            }
        ],
    }


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: run_llm_step.py <codegen|review> <round>")

    step_kind = sys.argv[1]
    round_number = int(sys.argv[2])
    message = load_message()
    payload = extract_payload(message)

    if step_kind == "codegen":
        result = run_codegen(payload, round_number)
    elif step_kind == "review":
        result = run_review(payload, round_number)
    else:
        raise SystemExit(f"unknown step kind: {step_kind}")

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
