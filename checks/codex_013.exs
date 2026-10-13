ExUnit.start(autorun: false)
Code.compiler_options(ignore_module_conflict: true)
Code.delete_path(Path.expand("_build/test/lib/alloy/ebin"))

snapshot = System.fetch_env!("ALLOY_013_SNAPSHOT")

replacements =
  ~w(lib/alloy/provider/codex.ex lib/alloy/provider/codex_session.ex lib/alloy/provider/error.ex)

excluded = MapSet.new(replacements, &Path.join(snapshot, &1))

sources =
  Enum.reject(Path.wildcard(Path.join(snapshot, "lib/**/*.ex")), &MapSet.member?(excluded, &1))

{:ok, _modules, diagnostics} =
  Kernel.ParallelCompiler.compile(sources ++ replacements, return_diagnostics: true)

if Enum.any?(Map.values(diagnostics), &(&1 != [])),
  do: raise("Compatibility compilation produced warnings: #{inspect(diagnostics)}")

{:ok, _apps} = Application.ensure_all_started(:telemetry)
{:ok, _supervisor} = Alloy.Application.start(:normal, [])

unless function_exported?(Alloy.Message, :normalize_for, 3),
  do: raise("Expected Alloy 0.13 message normalization")

Code.require_file("test/alloy/provider/codex_test.exs")
Code.require_file("test/alloy/provider/codex_session_test.exs")
Code.require_file("test/examples/minimal_host_test.exs")

result = File.cd!(snapshot, &ExUnit.run/0)
System.halt(if result.failures == 0, do: 0, else: 1)
