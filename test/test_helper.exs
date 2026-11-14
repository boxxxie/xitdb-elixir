Application.put_env(:ash, :default_string_length_count, :codepoints)
ExUnit.start()

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
