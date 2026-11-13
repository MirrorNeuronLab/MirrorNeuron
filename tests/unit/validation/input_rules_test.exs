defmodule MirrorNeuron.BlueprintValidation.InputRulesTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.{BlueprintValidation, JobBundle, Manifest}

  test "invalid regex is returned as a versioned validation issue" do
    report = failure_report(rule("["), "value")
    assert report["version"] == "validation.report/v1"
    assert [%{"code" => "manifest.input_validation.pattern_invalid"}] = report["issues"]
  end

  test "compound input values fail patterns without crashing" do
    for value <- [%{"nested" => true}, ["one", "two"]] do
      assert [%{"code" => "config.pattern_mismatch"}] =
               failure_report(rule("^ok$"), value)["issues"]
    end
  end

  test "false is preserved as the actual value in validation reports" do
    assert [%{"actual" => false}] = failure_report(rule("^true$"), false)["issues"]
  end

  test "diagnostics redact secret values and URL credentials" do
    secret = failure_report(%{rule("^ok$") | "path" => "api_token"}, "sensitive", "api_token")
    assert [%{"actual" => "[redacted]"}] = secret["issues"]

    url =
      failure_report(rule("^ok$"), "https://user:pass@example.test/path?token=secret&plain=yes")

    [issue] = url["issues"]
    refute issue["actual"] =~ "user:pass"
    refute issue["actual"] =~ "secret"
    assert issue["actual"] =~ "plain=yes"
  end

  test "optional missing input passes but case sensitive mismatch fails" do
    assert :ok =
             BlueprintValidation.run_input_validation(
               bundle(Map.put(rule("^ok$"), "required", false), %{})
             )

    assert [%{"code" => "config.pattern_mismatch"}] =
             failure_report(Map.put(rule("^ok$"), "ignore_case", false), "OK")["issues"]
  end

  defp rule(pattern), do: %{"type" => "pattern", "path" => "value", "pattern" => pattern}

  defp failure_report(rule, value, key \\ "value") do
    assert {:error, "input_validation_failed: " <> json} =
             BlueprintValidation.run_input_validation(bundle(rule, %{key => value}))

    Jason.decode!(json)
  end

  defp bundle(rule, config) do
    %JobBundle{
      manifest: %Manifest{
        metadata: %{},
        input_validation: [rule],
        nodes: [
          %{config: %{"environment" => %{"MN_BLUEPRINT_CONFIG_JSON" => Jason.encode!(config)}}}
        ]
      }
    }
  end
end
