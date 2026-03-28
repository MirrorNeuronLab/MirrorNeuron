#!/usr/bin/env python3
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
import os


def load_message() -> dict:
    return json.loads(Path(os.environ["MIRROR_NEURON_MESSAGE_FILE"]).read_text())


def extract_payload(message: dict) -> dict:
    body = message.get("body") or {}

    if isinstance(body, dict) and isinstance(body.get("sandbox"), dict):
        stdout = (body.get("sandbox", {}).get("stdout") or "").strip()
        if stdout:
            return json.loads(stdout)

    return body


def check_module_has_build_report(script_path: Path) -> tuple[bool, str]:
    spec = importlib.util.spec_from_file_location("candidate_module", script_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    exists = hasattr(module, "build_report")
    return exists, "build_report function exists" if exists else "build_report function missing"


def run_command(command: list[str], stdin_text: str | None = None) -> tuple[int, str, str]:
    proc = subprocess.run(
        command,
        input=stdin_text,
        text=True,
        capture_output=True,
        timeout=20,
    )
    return proc.returncode, proc.stdout, proc.stderr


def main() -> None:
    payload = extract_payload(load_message())
    task = payload["task"]
    validation = task["validation"]

    with tempfile.TemporaryDirectory(prefix="mirror_neuron_llm_validate_") as tmp_dir:
        tmp_path = Path(tmp_dir)
        script_path = tmp_path / payload.get("file_name", "inventory_report.py")
        sample_path = tmp_path / "inventory.json"
        script_path.write_text(payload["code"])
        sample_path.write_text(json.dumps(task["sample_records"], indent=2))

        assertions = []

        ok, details = check_module_has_build_report(script_path)
        assertions.append({"name": "module_has_build_report", "passed": ok, "details": details})

        json_code, json_stdout, json_stderr = run_command(
            [
                sys.executable,
                str(script_path),
                "--input",
                str(sample_path),
                "--format",
                "json",
                "--low-stock-threshold",
                str(validation["low_stock_threshold"]),
            ]
        )
        if json_code == 0:
            parsed_json = json.loads(json_stdout)
            expected = validation["expected"]
            json_ok = (
                parsed_json.get("total_quantity") == expected["total_quantity"]
                and round(float(parsed_json.get("total_value")), 2) == expected["total_value"]
                and parsed_json.get("category_totals") == expected["category_totals"]
                and parsed_json.get("low_stock_skus") == expected["low_stock_skus"]
            )
            assertions.append(
                {
                    "name": "json_cli_matches_expected",
                    "passed": json_ok,
                    "details": parsed_json if json_ok else {"stdout": json_stdout, "stderr": json_stderr},
                }
            )
        else:
            assertions.append(
                {
                    "name": "json_cli_matches_expected",
                    "passed": False,
                    "details": {"exit_code": json_code, "stdout": json_stdout, "stderr": json_stderr},
                }
            )

        stdin_code, stdin_stdout, stdin_stderr = run_command(
            [
                sys.executable,
                str(script_path),
                "--format",
                "json",
                "--low-stock-threshold",
                str(validation["low_stock_threshold"]),
            ],
            stdin_text=json.dumps(task["sample_records"]),
        )
        stdin_ok = False
        if stdin_code == 0:
            stdin_json = json.loads(stdin_stdout)
            stdin_ok = stdin_json.get("low_stock_skus") == validation["expected"]["low_stock_skus"]

        assertions.append(
            {
                "name": "stdin_json_mode_works",
                "passed": stdin_ok,
                "details": stdin_stdout if stdin_ok else {"exit_code": stdin_code, "stdout": stdin_stdout, "stderr": stdin_stderr},
            }
        )

        text_code, text_stdout, text_stderr = run_command(
            [
                sys.executable,
                str(script_path),
                "--input",
                str(sample_path),
                "--format",
                "text",
                "--low-stock-threshold",
                str(validation["low_stock_threshold"]),
            ]
        )
        normalized_text = text_stdout.lower()
        text_ok = (
            text_code == 0
            and "inventory report" in normalized_text
            and "total quantity" in normalized_text
            and "a-100" in normalized_text
            and "c-300" in normalized_text
        )
        assertions.append(
            {
                "name": "text_cli_mode_works",
                "passed": text_ok,
                "details": text_stdout if text_ok else {"exit_code": text_code, "stdout": text_stdout, "stderr": text_stderr},
            }
        )

        tests_passed = all(assertion["passed"] for assertion in assertions)
        result = {
            "kind": "validation_result",
            "task": task,
            "file_name": payload.get("file_name", "inventory_report.py"),
            "tests_passed": tests_passed,
            "summary": "All validator assertions passed." if tests_passed else "One or more validator assertions failed.",
            "assertions": assertions,
            "history": payload.get("history", []),
            "code": payload["code"],
        }

        print(json.dumps(result, indent=2))
        if not tests_passed:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
