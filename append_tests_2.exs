new_tests = """

  test "POST /api/v1/bundles/upload requires a bundle payload" do
    conn = conn(:post, "/api/v1/bundles/upload", %{}) |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 400
    assert String.contains?(Jason.decode!(conn.resp_body)["error"], "Missing 'bundle' file upload")
  end
end
"""

path = "tests/integration/mirror_neuron/api/router_test.exs"
content = File.read!(path)
content = String.replace(content, ~r/\nend\s*$/, new_tests)
File.write!(path, content)
