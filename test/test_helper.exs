Application.put_env(:ash, :default_string_length_count, :codepoints)
Xitdb.Cursor.register_beam_tracer()
ExUnit.start(exclude: if(match?({:unix, _}, :os.type()), do: [], else: [:unix]))

if Code.ensure_loaded?(Ash.DataLayer) do
  Xitdb.Ash.TestSandbox.init()

  {:ok, _} =
    Xitdb.TestSupport.MdmStore.start_link(
      path: :memory,
      domains: [Xitdb.TestSupport.MdmDomain]
    )

  {:ok, _} =
    Xitdb.TestSupport.AppStore.start_link(
      path: :memory,
      domains: [Xitdb.TestSupport.AppDomain]
    )
end
