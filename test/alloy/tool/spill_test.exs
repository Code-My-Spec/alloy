defmodule Alloy.Tool.SpillTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool.Spill

  describe "normalize/2" do
    test "off when nil" do
      assert Spill.normalize(nil, "/w") == nil
    end

    test "resolves :dir against the working directory and fills defaults" do
      assert Spill.normalize([dir: "tmp/out"], "/w") ==
               %{dir: "/w/tmp/out", threshold: 10_000, preview_chars: 2_000, tail_chars: 1_000}
    end

    test "needs a :dir" do
      assert_raise ArgumentError, ~r/needs a :dir/, fn -> Spill.normalize([], "/w") end
    end

    test "refuses a preview and tail that cover the whole threshold" do
      assert_raise ArgumentError, fn ->
        Spill.normalize([dir: "d", threshold: 100, preview_chars: 80, tail_chars: 20], "/w")
      end
    end
  end

  test "Alloy.Agent.Config resolves it from opts" do
    config =
      Alloy.Agent.Config.from_opts(
        provider: Alloy.Provider.Test,
        working_directory: "/w",
        tool_result_spill: [dir: "out", threshold: 500, preview_chars: 100, tail_chars: 0]
      )

    assert config.tool_result_spill ==
             %{dir: "/w/out", threshold: 500, preview_chars: 100, tail_chars: 0}
  end
end
