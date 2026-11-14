# Reference: Ash DataLayer Phase 1 Verification Suite

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_phase1_verification_suite_20261111`](./index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Scope:** Complete Phase 1 verification architecture (Pattern D/E `ExUnitProperties` + 4-Layer ATDD Executable Specifications) and atomic validation adjustments.

---

Phase 1 verification splits cleanly across two test architectures: **Pattern D/E (`ExUnitProperties` + direct `ExUnit`)** for low-level binary key codecs, B+Tree indexers, compile-time Spark verifiers, and BM25 posting invariants, and **4-Layer ATDD (`FeatureScenario` -> DSL -> Protocol Driver -> SUT)** for `Ash.Policy.Authorizer`, cross-store relationships, partial identities, savepoints, and `AshPhoenix.Form` workflows.

### Important `Mutator`, `Store` & `TestSandbox` Pre-Checks Before Running Atomic Validation Specs

1. **Pre-Update `changeset.atomics`, `{:_atomic_ref, field}` Substitution & `:unknown` Relational Fallback (`lib/xitdb/ash/mutator.ex`):**
   In Ash 3, `Ash.Resource.Validation` `atomic/3` callbacks store `{fields, failure_condition_expr, error_expr}` (or `{failure_condition_expr, error_expr}`) in `changeset.atomic_validations`, where **`failure_condition_expr` evaluates to `true` when the validation fails** (`CASE WHEN cond THEN error(...)`). Verify that `Mutator` implements all three Wave 2 invariants from [`ash_mutator_and_cascades_20261111`](../ash_mutator_and_cascades_20261111/reference.md):
   - Evaluate `changeset.atomics` against the **pre-update** `current_record` snapshot first and merge `allowed_attrs` + `evaluated_atomics` into `post_record`.
   - In `verify_atomic_validations/4`, substitute `{:_atomic_ref, field}` template nodes (`^atomic_ref(:email)`) with `Map.get(post_record, field)` (`substitute_atomic_refs/2`) while evaluating bare `%Ash.Query.Ref{}` nodes against `current_record` on updates/upserts/destroys (or `post_record` on creates).
   - Whenever `Ash.Expr.eval/2` (`unknown_on_unknown_refs?: true`) returns `:unknown` (such as relational/cross-store `exists(...)` policies), fall back to `Ash.Filter.Runtime.filter_matches/4` (`authorize?: false`)—**never** mapping `:unknown` to `{:ok, nil}`.

```elixir
defp verify_atomic_validations(pre_record, post_record, resource, %Ash.Changeset{} = changeset) do
  validations = Map.get(changeset, :atomic_validations, [])
  actor = get_in(changeset.context, [:private, :actor])

  Enum.reduce_while(validations, :ok, fn entry, :ok ->
    {failure_expr, error_expr} =
      case entry do
        {_fields, cond_expr, err_expr} -> {cond_expr, err_expr}
        {cond_expr, err_expr} -> {cond_expr, err_expr}
      end

    resolved_cond = substitute_atomic_refs(failure_expr, post_record)

    case eval_boolean_expr(resolved_cond, pre_record, resource, changeset, actor) do
      {:ok, true} ->
        resolved_err = substitute_atomic_refs(error_expr, post_record)

        {:halt,
         {:error,
          materialize_validation_error(resolved_err, post_record, resource, changeset, actor)}}

      {:ok, false} ->
        {:cont, :ok}

      {:error, _} = err ->
        {:halt, err}
    end
  end)
end
```

2. **Re-Entrant `Store.mutate/3` Over `{db, moment}` Working Snapshots (`lib/xitdb/ash/store.ex`):**
   `Organization.rename_and_reindex` invokes `Xitdb.Ash.Store.mutate(MdmStore, ...)` inside an `after_action` hook while `DataLayer.update/2` is already executing. Verify `Store.run_with_working_db/5` stores `{:xitdb_tx_state, store}` (`{db, moment}`) and `{:xitdb_tx_db, store}` (`Xitdb.as_of(db, moment)`) in the process dictionary for **both** `run_leased_transaction/3` (non-sandbox) and `TestSandbox.transact/3` (sandbox), and `Store.mutate/3` checks `in_transaction?(store)` first so nested `mutate/3` calls advance `{db, moment}` in place without deadlocking on `GenServer.call`.

3. **Snapshot-Preserving Isolated Sandbox Clones & Cleanup on Re-Checkout (`lib/xitdb/ash/test_sandbox.ex`):**
   `IndexerAndSearchPropertiesTest` calls `TestSandbox.checkout([MdmStore])` inside `check all` while `Xitdb.AshCase` already checked out `[MdmStore, AppStore]` in `setup`. Ensure `TestSandbox` clones the store's baseline state via `Xitdb.compact!/1` into an isolated `:memory` `%Xitdb{}` handle per checkout (preserving baseline seeds without mutating `Snapshot.committed_db(store)`), `checkin/2` closes any prior checkout before re-checking out, and `TestSandbox.Coordinator` traps exits and closes isolated `:memory` `%Xitdb{}` handles in `terminate/2`.

---

## 1. `xitdb/mix.exs` Test Config & Harness (`test/support/`)

Ensure `elixirc_paths(:test)` includes `"test/support"`, `aliases/0` defines `precommit`, and `deps/0` includes `:stream_data` + `:ash_phoenix` for test verification:

```elixir
# In xitdb/mix.exs:
def project do
  [
    # ...
    elixirc_paths: elixirc_paths(Mix.env()),
    aliases: aliases(),
    deps: deps()
  ]
end

def cli do
  [preferred_envs: [precommit: :test]]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]

defp aliases do
  [
    precommit: [
      "format --check-formatted",
      "compile --warnings-as-errors",
      "test"
    ]
  ]
end

defp deps do
  [
    {:ash, "~> 3.37 and >= 3.37.2", optional: true},
    {:spark, "~> 2.2", optional: true},
    {:nimble_options, "~> 1.1 and >= 1.1.1"},
    {:telemetry, "~> 1.3"},
    {:ash_phoenix, "~> 2.1", only: :test},
    {:simple_sat, "~> 0.1", only: :test},
    {:stream_data, "~> 1.1", only: [:dev, :test]},
    {:ex_doc, "~> 0.35", only: :dev, runtime: false}
  ]
end
```

**`test/test_helper.exs`**

```elixir
ExUnit.start()

if Code.ensure_loaded?(Ash.DataLayer) do
  Xitdb.Ash.TestSandbox.init()
  {:ok, _} = Xitdb.TestSupport.MdmStore.start_link(path: :memory, domains: [Xitdb.TestSupport.MdmDomain])
  {:ok, _} = Xitdb.TestSupport.AppStore.start_link(path: :memory, domains: [Xitdb.TestSupport.AppDomain])
end
```

**`test/support/ash_case.ex`**

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.FeatureScenario do
    @moduledoc """
    Compiles `@given`, `@upon`, `@whenever`, and `@then` steps into a piped `ctx` test
    while preserving caller line metadata.
    """

    defmacro scenario(description, do: block) do
      lines =
        case block do
          {:__block__, _, exprs} -> exprs
          single -> [single]
        end

      ctx_var = Macro.unique_var(:ctx, __MODULE__)

      init_ctx =
        quote do
          Xitdb.TestDSL.WorkspaceDSL.new_world(unquote(ctx_var))
        end

      piped_steps =
        Enum.reduce(lines, init_ctx, fn
          {:@, step_meta, [{step_kind, _, [call]}]}, acc
          when step_kind in [:given, :upon, :whenever, :then] ->
            step_line = Keyword.get(step_meta, :line, __CALLER__.line)
            piped = Macro.pipe(acc, call, 0)
            Macro.update_meta(piped, &Keyword.put(&1, :line, step_line))

          other_ast, _acc ->
            err_line =
              case other_ast do
                {_, meta, _} when is_list(meta) -> Keyword.get(meta, :line, __CALLER__.line)
                _ -> __CALLER__.line
              end

            raise CompileError,
              file: __CALLER__.file,
              line: err_line,
              description:
                "Only @given, @upon, @whenever, and @then steps are allowed inside scenario/2. Got: #{Macro.to_string(other_ast)}"
        end)

      quote line: __CALLER__.line do
        test unquote(description), unquote(ctx_var) do
          _ = unquote(piped_steps)
          :ok
        end
      end
    end
  end

  defmodule Xitdb.AshCase do
    @moduledoc false
    use ExUnit.CaseTemplate

    using do
      quote do
        use ExUnit.Case, async: true
        import Xitdb.FeatureScenario, only: [scenario: 2]
      end
    end

    setup tags do
      :ok =
        Xitdb.Ash.TestSandbox.checkout(
          [Xitdb.TestSupport.MdmStore, Xitdb.TestSupport.AppStore],
          shared: not Map.get(tags, :async, true)
        )

      :ok
    end
  end
end
```

**`test/support/ash_test_domain.ex`**

Defines two isolated stores (`MdmStore` and `AppStore`) mirroring CAASA Connect's dual-store topology (`Organization`, `MemberProfile` with `field_policies` and `search_field` firm resolution, `Event`, `nested_in` `AgendaSession`, `TableTalkSeat` with partial `where: expr(status == :confirmed)` identity, and cross-store `DirectMessage`).

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.TestSupport.MdmStore do
    @moduledoc false
    use Xitdb.Ash.Store
  end

  defmodule Xitdb.TestSupport.AppStore do
    @moduledoc false
    use Xitdb.Ash.Store
  end

  defmodule Xitdb.TestSupport.Validations.NoConsumerEmailDomain do
    @moduledoc false
    use Ash.Resource.Validation
    import Ash.Expr

    @blocked ["gmail.com", "yahoo.com"]

    @impl true
    def validate(changeset, _opts, _context) do
      case Ash.Changeset.get_attribute(changeset, :email) do
        nil ->
          :ok

        email ->
          str = email |> to_string() |> String.downcase()

          if Enum.any?(@blocked, &String.ends_with?(str, "@" <> &1)) do
            {:error, field: :email, message: "must use a corporate domain"}
          else
            :ok
          end
      end
    end

    @impl true
    def atomic(_changeset, _opts, _context) do
      {:atomic, [:email],
       expr(
         not is_nil(^atomic_ref(:email)) and
           (contains(^atomic_ref(:email), "@gmail.com") or
              contains(^atomic_ref(:email), "@yahoo.com"))
       ),
       expr(
         error(Ash.Error.Changes.InvalidAttribute,
           field: :email,
           message: "must use a corporate domain"
         )
       )}
    end
  end

  defmodule Xitdb.TestSupport.Organization do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :organizations
      search_field :name, boost: 3.0
      search_field :mandate, boost: 1.5
    end

    attributes do
      integer_primary_key :id
      attribute :name, :string, allow_nil?: false, public?: true
      attribute :domain, :ci_string, allow_nil?: false, public?: true
      attribute :slug, :ci_string, allow_nil?: false, public?: true
      attribute :mandate, :string, public?: true
    end

    identities do
      identity :unique_domain, [:domain]
      identity :unique_slug, [:slug]
    end

    relationships do
      has_many :profiles, Xitdb.TestSupport.MemberProfile, destination_attribute: :organization_id
      has_many :organized_events, Xitdb.TestSupport.Event, destination_attribute: :organizer_id
    end

    actions do
      defaults [:read, :destroy]

      create :register do
        accept [:name, :domain, :slug, :mandate]
      end

      update :rename_and_reindex do
        require_atomic? false
        accept [:name, :mandate]

        change after_action(fn _changeset, org, _ctx ->
                 profiles =
                   Xitdb.TestSupport.MdmDomain.list_org_profiles!(org.id, authorize?: false)

                 _ =
                   Xitdb.Ash.Store.mutate(Xitdb.TestSupport.MdmStore, fn snapshot ->
                     {:ok, Xitdb.Ash.Search.reindex_records(snapshot, Xitdb.TestSupport.MemberProfile, profiles), :ok}
                   end)

                 {:ok, org}
               end)
      end
    end
  end

  defmodule Xitdb.TestSupport.MemberProfile do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :profiles

      index [:visibility, :role]

      search_field :full_name, boost: 3.0
      search_field :headline, boost: 1.5

      search_field :firm_name,
        boost: 2.0,
        resolver: fn profile, db ->
          Xitdb.Ash.Search.lookup_field(db, :organizations, profile.organization_id, "name")
        end

      search_field :firm_mandate,
        boost: 1.2,
        resolver: fn profile, db ->
          Xitdb.Ash.Search.lookup_field(db, :organizations, profile.organization_id, "mandate")
        end

      references do
        reference :organization, on_delete: :nilify
      end
    end

    attributes do
      integer_primary_key :id
      attribute :email, :ci_string, allow_nil?: false, public?: true
      attribute :full_name, :string, allow_nil?: false, public?: true
      attribute :headline, :string, public?: true

      attribute :role, :atom,
        constraints: [one_of: [:member, :steward]],
        default: :member,
        allow_nil?: false,
        public?: true

      attribute :visibility, :atom,
        constraints: [one_of: [:public, :private]],
        default: :public,
        allow_nil?: false,
        public?: true

      attribute :compensation_band, :string, public?: true
      attribute :view_count, :integer, default: 0, allow_nil?: false, public?: true
    end

    identities do
      identity :unique_email, [:email]
    end

    relationships do
      belongs_to :organization, Xitdb.TestSupport.Organization, allow_nil?: true, public?: true

      has_many :sent_messages, Xitdb.TestSupport.DirectMessage do
        domain Xitdb.TestSupport.AppDomain
        destination_attribute :sender_id
      end
    end

    calculations do
      calculate :display_badge,
                :string,
                expr(full_name <> " (" <> headline <> ")"),
                public?: true
    end

    aggregates do
      count :sent_message_count, :sent_messages, public?: true
    end

    validations do
      validate Xitdb.TestSupport.Validations.NoConsumerEmailDomain do
        where [changing(:email)]
      end
    end

    policies do
      bypass actor_attribute_equals(:role, :steward) do
        authorize_if always()
      end

      policy action_type(:read) do
        authorize_if expr(visibility == :public)
        authorize_if expr(id == ^actor(:id))
      end

      policy action_type(:create) do
        authorize_if always()
      end

      policy action_type([:update, :destroy]) do
        authorize_if expr(id == ^actor(:id))
      end
    end

    field_policies do
      field_policy :compensation_band do
        authorize_if actor_attribute_equals(:role, :steward)
        authorize_if expr(id == ^actor(:id))
      end

      field_policy :* do
        authorize_if always()
      end
    end

    actions do
      defaults [:read, :destroy]

      read :for_organization do
        argument :organization_id, :integer, allow_nil?: false
        filter expr(organization_id == ^arg(:organization_id))
      end

      create :enrol do
        accept [:email, :full_name, :headline, :role, :visibility, :compensation_band, :organization_id]
        upsert? true
        upsert_identity :unique_email
        upsert_fields [:full_name, :headline, :visibility, :organization_id]
      end

      create :submit_application do
        accept [:email, :full_name, :headline, :visibility, :compensation_band, :organization_id]
      end

      update :edit_profile do
        accept [:headline, :visibility, :compensation_band]
      end

      update :change_email do
        argument :new_email, :ci_string, allow_nil?: false
        change atomic_update(:email, expr(^arg(:new_email)))
      end

      update :record_profile_view do
        accept []
        change atomic_update(:view_count, expr(view_count + 1))
      end
    end
  end

  defmodule Xitdb.TestSupport.Event do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :events

      references do
        reference :organizer, on_delete: :restrict
      end
    end

    attributes do
      integer_primary_key :id
      attribute :title, :string, allow_nil?: false, public?: true
      attribute :location_city, :string, public?: true
      attribute :location_name, :string, allow_nil?: false, public?: true
    end

    relationships do
      belongs_to :organizer, Xitdb.TestSupport.Organization, allow_nil?: false, public?: true
      has_many :sessions, Xitdb.TestSupport.AgendaSession, destination_attribute: :event_id
    end

    calculations do
      calculate :effective_location,
                :string,
                expr(if(is_nil(location_city), location_name, location_city)),
                public?: true
    end

    aggregates do
      count :session_count, :sessions, public?: true
      sum :total_capacity, :sessions, :capacity, default: 0, public?: true
    end

    actions do
      defaults [:read, :destroy]

      create :schedule do
        accept [:title, :location_city, :location_name, :organizer_id]
      end
    end
  end

  defmodule Xitdb.TestSupport.AgendaSession do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :agenda_sessions
      nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many
      search_field :title, boost: 2.0
    end

    attributes do
      integer_primary_key :id
      attribute :title, :string, allow_nil?: false, public?: true
      attribute :capacity, :integer, allow_nil?: false, default: 30, public?: true
    end

    identities do
      identity :unique_session_title_per_event, [:event_id, :title]
    end

    relationships do
      belongs_to :event, Xitdb.TestSupport.Event, allow_nil?: false, public?: true
      has_many :seats, Xitdb.TestSupport.TableTalkSeat, destination_attribute: :session_id
    end

    actions do
      defaults [:read, :destroy]

      create :add_session do
        accept [:event_id, :title, :capacity]
      end
    end
  end

  defmodule Xitdb.TestSupport.TableTalkSeat do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :table_talk_seats

      references do
        reference :session, on_delete: :delete
      end
    end

    attributes do
      integer_primary_key :id
      attribute :seat_number, :integer, allow_nil?: false, public?: true

      attribute :status, :atom,
        constraints: [one_of: [:confirmed, :cancelled]],
        default: :confirmed,
        allow_nil?: false,
        public?: true
    end

    identities do
      identity :unique_confirmed_seat, [:session_id, :seat_number] do
        where expr(status == :confirmed)
      end
    end

    relationships do
      belongs_to :session, Xitdb.TestSupport.AgendaSession, allow_nil?: false, public?: true
      belongs_to :profile, Xitdb.TestSupport.MemberProfile, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, :destroy]

      create :reserve do
        accept [:session_id, :profile_id, :seat_number, :status]
      end

      update :cancel do
        accept []
        change set_attribute(:status, :cancelled)
      end
    end
  end

  defmodule Xitdb.TestSupport.DirectMessage do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.AppDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.AppStore
      collection :direct_messages
      index [:recipient_id, :archived?]
    end

    attributes do
      integer_primary_key :id
      attribute :recipient_id, :integer, allow_nil?: false, public?: true
      attribute :body, :string, allow_nil?: false, public?: true
      attribute :archived?, :boolean, default: false, allow_nil?: false, public?: true
    end

    relationships do
      belongs_to :sender, Xitdb.TestSupport.MemberProfile do
        domain Xitdb.TestSupport.MdmDomain
        allow_nil? false
        public? true
      end
    end

    actions do
      defaults [:read, :destroy]

      create :send_message do
        accept [:sender_id, :recipient_id, :body]
      end

      update :archive do
        accept []
        change set_attribute(:archived?, true)
      end
    end
  end

  defmodule Xitdb.TestSupport.MdmDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Xitdb.TestSupport.Organization do
        define :register_organization, action: :register
        define :rename_organization, action: :rename_and_reindex
        define :destroy_organization, action: :destroy
        define :get_organization, action: :read, get_by: [:id]
      end

      resource Xitdb.TestSupport.MemberProfile do
        define :enrol_member, action: :enrol
        define :submit_application, action: :submit_application
        define :edit_profile, action: :edit_profile
        define :change_email, action: :change_email, args: [:new_email]
        define :record_profile_view, action: :record_profile_view
        define :destroy_profile, action: :destroy
        define :list_profiles, action: :read
        define :list_org_profiles, action: :for_organization, args: [:organization_id]
        define :get_profile, action: :read, get_by: [:id]
      end

      resource Xitdb.TestSupport.Event do
        define :schedule_event, action: :schedule
        define :destroy_event, action: :destroy
        define :get_event, action: :read, get_by: [:id]
      end

      resource Xitdb.TestSupport.AgendaSession do
        define :add_session, action: :add_session
        define :get_session, action: :read, get_by: [:id]
        define :list_sessions, action: :read
      end

      resource Xitdb.TestSupport.TableTalkSeat do
        define :reserve_seat, action: :reserve
        define :cancel_seat, action: :cancel
        define :list_seats, action: :read
      end
    end
  end

  defmodule Xitdb.TestSupport.AppDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Xitdb.TestSupport.DirectMessage do
        define :send_message, action: :send_message
        define :archive_message, action: :archive
        define :list_messages, action: :read
      end
    end
  end
end
```

---

## 2. Pattern D & E: `ExUnitProperties` & Storage Invariants (`test/xitdb/ash/`)

**`test/xitdb/ash/codec_properties_test.exs`**

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.CodecPropertiesTest do
    use ExUnit.Case, async: true
    use ExUnitProperties

    alias Ash.Resource.Attribute
    alias Xitdb.Ash.Codec
    alias Xitdb.TestSupport.MemberProfile

    @min_i64 -9_223_372_036_854_775_808
    @max_i64 9_223_372_036_854_775_807

    property "encode_i64_be/1 round-trips and preserves strict signed ordering across all 64-bit bounds" do
      i64_gen =
        one_of([
          integer(@min_i64..@max_i64),
          member_of([@min_i64, @min_i64 + 1, -1, 0, 1, @max_i64 - 1, @max_i64])
        ])

      check all a <- i64_gen, b <- i64_gen do
        bin_a = Codec.encode_i64_be(a)
        bin_b = Codec.encode_i64_be(b)

        assert Codec.decode_i64_be(bin_a) == a
        assert Codec.decode_i64_be(bin_b) == b
        assert compare_terms(bin_a, bin_b) == compare_terms(a, b)
      end
    end

    property "encode_f64_be/1 normalizes -0.0/+0.0 and preserves IEEE-754 ordering" do
      assert Codec.encode_f64_be(-0.0) == Codec.encode_f64_be(+0.0)

      check all a <- float(min: -1.0e12, max: 1.0e12),
                b <- float(min: -1.0e12, max: 1.0e12) do
        assert compare_terms(Codec.encode_f64_be(a), Codec.encode_f64_be(b)) ==
                 compare_terms(a, b)
      end
    end

    property "encode_decimal_key/1 is scale-invariant (60.0 == 60.00) and order-preserving" do
      assert Codec.encode_decimal_key(Decimal.new("60")) ==
               Codec.encode_decimal_key(Decimal.new("60.000"))

      assert Codec.encode_decimal_key(Decimal.new("-0.00")) ==
               Codec.encode_decimal_key(Decimal.new("0"))

      dec_gen =
        gen all sign <- member_of(["", "-"]),
                whole <- integer(0..999_999),
                frac <- integer(0..9999),
                trailing <- string(?0..?0, max_length: 3) do
          Decimal.new("#{sign}#{whole}.#{frac}#{trailing}")
        end

      check all a <- dec_gen, b <- dec_gen do
        assert compare_terms(Codec.encode_decimal_key(a), Codec.encode_decimal_key(b)) ==
                 Decimal.compare(a, b)
      end
    end

    property "composite secondary index keys escape interior NUL bytes without collisions" do
      str_attr = %Attribute{name: :a, type: Ash.Type.String, constraints: []}
      int_attr = %Attribute{name: :b, type: Ash.Type.Integer, constraints: []}
      attrs = [str_attr, int_attr]

      bin_with_nuls =
        gen all bytes <- list_of(one_of([constant(0), constant(255), integer(97..102)]), max_length: 12) do
          :erlang.list_to_binary(bytes)
        end

      check all s1 <- bin_with_nuls,
                s2 <- bin_with_nuls,
                n1 <- integer(-500..500),
                n2 <- integer(-500..500) do
        k1 = Codec.encode_index_key(attrs, [s1, n1])
        k2 = Codec.encode_index_key(attrs, [s2, n2])

        assert compare_terms(k1, k2) == compare_terms({s1, n1}, {s2, n2})
      end
    end

    property "tenant-scoped composite identity keys never collide across boundaries or tenants" do
      fake_identity = %{
        name: :composite,
        keys: [:full_name, :headline],
        nils_distinct?: false,
        all_tenants?: false
      }

      seg_gen = string([?a..?c, ?:, ?0], min_length: 0, max_length: 8)

      check all f1 <- seg_gen,
                h1 <- seg_gen,
                t1 <- one_of([constant(nil), seg_gen]),
                f2 <- seg_gen,
                h2 <- seg_gen,
                t2 <- one_of([constant(nil), seg_gen]) do
        {:ok, k1} = Codec.encode_identity_key(MemberProfile, fake_identity, %{full_name: f1, headline: h1}, t1)
        {:ok, k2} = Codec.encode_identity_key(MemberProfile, fake_identity, %{full_name: f2, headline: h2}, t2)

        if {t1, f1, h1} == {t2, f2, h2} do
          assert k1 == k2
        else
          assert k1 != k2
        end
      end
    end

    defp compare_terms(a, b) when a < b, do: :lt
    defp compare_terms(a, b) when a > b, do: :gt
    defp compare_terms(_a, _b), do: :eq
  end
end
```

**`test/xitdb/ash/indexer_and_search_properties_test.exs`**

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.IndexerAndSearchPropertiesTest do
    use Xitdb.AshCase
    use ExUnitProperties

    alias Spark.Error.DslError
    alias Xitdb.Ash.{Indexer, Search, Store}
    alias Xitdb.Ash.Search.Storage, as: SearchStorage
    alias Xitdb.TestSupport.{AgendaSession, MdmDomain, MdmStore, Organization}

    property "BM25 corpus doc_count and total_len never drift across arbitrary insert/update/delete streams" do
      vocab = ["polar", "asset", "macro", "credit", "quant", "infrastructure", "yield"]

      op_gen =
        one_of([
          tuple({constant(:upsert), integer(1..6), list_of(member_of(vocab), min_length: 1, max_length: 5)}),
          tuple({constant(:delete), integer(1..6)})
        ])

      check all ops <- list_of(op_gen, min_length: 5, max_length: 25) do
        :ok = Xitdb.Ash.TestSandbox.checkout([MdmStore])
        live_orgs = apply_search_ops(ops, %{})
        db = Store.current_db(MdmStore)

        stats = SearchStorage.read_corpus_stats(db, "organizations")
        assert stats.doc_count == map_size(live_orgs)

        # Deleting every remaining record restores corpus stats and term B+Tree to exact zero
        Enum.each(Map.values(live_orgs), &MdmDomain.destroy_organization!(&1))
        empty_db = Store.current_db(MdmStore)
        assert SearchStorage.read_corpus_stats(empty_db, "organizations") == %{doc_count: 0, total_len: 0}
        assert Search.ids(Organization, "polar macro credit", match: :any) == []
      end
    end

    test "destroying an Event purges nested AgendaSession _parent, identity, and BM25 search slots" do
      uid = System.unique_integer([:positive])

      org =
        MdmDomain.register_organization!(%{
          name: "Summit Host #{uid}",
          domain: "host-#{uid}.ca",
          slug: "host-#{uid}"
        })

      other_org =
        MdmDomain.register_organization!(%{
          name: "Other Host #{uid}",
          domain: "other-#{uid}.ca",
          slug: "other-#{uid}"
        })

      event =
        MdmDomain.schedule_event!(%{
          title: "Fall Allocators Forum",
          location_name: "Fairmont Queen Elizabeth",
          organizer_id: other_org.id
        })

      session =
        MdmDomain.add_session!(%{
          event_id: event.id,
          title: "Sovereign Wealth Co-Investments #{uid}",
          capacity: 45
        })

      # Direct O(log N) lookup by session ID without passing event_id
      assert MdmDomain.get_session!(session.id).title =~ "Sovereign Wealth"
      assert Search.ids(AgendaSession, "sovereign") == [session.id]

      # Parent `on_delete: :restrict` blocks deleting `other_org` while `event` exists
      assert_raise Ash.Error.Invalid, fn ->
        MdmDomain.destroy_organization!(other_org)
      end

      :ok = MdmDomain.destroy_event!(event)

      db = Store.current_db(MdmStore)
      assert Indexer.fetch_cursor(db, AgendaSession, session.id) == :none
      assert Search.ids(AgendaSession, "sovereign") == []

      # Destroying `event` releases the `on_delete: :restrict` constraint on `other_org`
      assert :ok = MdmDomain.destroy_organization!(other_org)
      assert :ok = MdmDomain.destroy_organization!(org)
    end

    test "VerifyNoSqlFragments rejects SQL fragment(...) calculations at compile time" do
      uid = System.unique_integer([:positive])
      res_mod = Module.concat(Xitdb.TestSupport, "InvalidFragmentResource#{uid}")

      # Spark runs verifiers in `@after_verify`, so errors surface as compiler diagnostics.
      {compiled, diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string("""
          defmodule Xitdb.TestSupport.InvalidFragmentDomain#{uid} do
            use Ash.Domain, validate_config_inclusion?: false

            resources do
              resource Xitdb.TestSupport.InvalidFragmentResource#{uid}
            end
          end

          defmodule Xitdb.TestSupport.InvalidFragmentResource#{uid} do
            use Ash.Resource,
              domain: Xitdb.TestSupport.InvalidFragmentDomain#{uid},
              data_layer: Xitdb.Ash.DataLayer

            xitdb do
              store Xitdb.TestSupport.MdmStore
              collection :invalid_fragments
            end

            attributes do
              integer_primary_key :id
              attribute :city, :string
            end

            calculations do
              calculate :bad_loc, :string, expr(fragment("COALESCE(?, 'N/A')", city))
            end
          end
          """)
        end)

      assert Enum.any?(diagnostics, &(&1.message =~ ~r/SQL `fragment\(\.\.\.\)` .* is not supported/))
      assert Enum.any?(compiled, fn {m, _} -> m == res_mod end)

      assert {:error, %DslError{message: msg}} =
               Xitdb.Ash.Verifiers.VerifyNoSqlFragments.verify(res_mod.spark_dsl_config())

      assert msg =~ ~r/SQL `fragment\(\.\.\.\)` .* is not supported/
    end

    test "VerifyCrossStoreReferences rejects on_delete cascades across distinct .xit stores" do
      uid = System.unique_integer([:positive])
      res_mod = Module.concat(Xitdb.TestSupport, "InvalidCrossStoreRef#{uid}")

      # Spark runs verifiers in `@after_verify`, so errors surface as compiler diagnostics.
      {compiled, diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string("""
          defmodule Xitdb.TestSupport.InvalidCrossStoreDomain#{uid} do
            use Ash.Domain, validate_config_inclusion?: false

            resources do
              resource Xitdb.TestSupport.InvalidCrossStoreRef#{uid}
            end
          end

          defmodule Xitdb.TestSupport.InvalidCrossStoreRef#{uid} do
            use Ash.Resource,
              domain: Xitdb.TestSupport.InvalidCrossStoreDomain#{uid},
              data_layer: Xitdb.Ash.DataLayer

            xitdb do
              store Xitdb.TestSupport.AppStore
              collection :invalid_cross_refs

              references do
                reference :sender, on_delete: :delete
              end
            end

            attributes do
              integer_primary_key :id
            end

            relationships do
              belongs_to :sender, Xitdb.TestSupport.MemberProfile do
                domain Xitdb.TestSupport.MdmDomain
              end
            end
          end
          """)
        end)

      assert Enum.any?(diagnostics, &(&1.message =~ ~r/[Cc]ross-store .*`?on_delete: :delete`?/))
      assert Enum.any?(compiled, fn {m, _} -> m == res_mod end)

      assert {:error, %DslError{message: msg}} =
               Xitdb.Ash.Verifiers.VerifyCrossStoreReferences.verify(res_mod.spark_dsl_config())

      assert msg =~ ~r/[Cc]ross-store .*`?on_delete: :delete`?/
    end

    defp apply_search_ops(ops, state) do
      uid = System.unique_integer([:positive])

      Enum.reduce(ops, state, fn
        {:upsert, slot, words}, acc ->
          phrase = Enum.join(words, " ")

          case Map.get(acc, slot) do
            nil ->
              org =
                MdmDomain.register_organization!(%{
                  name: phrase,
                  domain: "slot-#{slot}-#{uid}.ca",
                  slug: "slot-#{slot}-#{uid}",
                  mandate: phrase
                })

              Map.put(acc, slot, org)

            existing ->
              updated = MdmDomain.rename_organization!(existing, %{name: phrase, mandate: phrase})
              Map.put(acc, slot, updated)
          end

        {:delete, slot}, acc ->
          case Map.pop(acc, slot) do
            {nil, unchanged} ->
              unchanged

            {existing, rest} ->
              :ok = MdmDomain.destroy_organization!(existing)
              rest
          end
      end)
    end
  end
end
```

---

## 3. 4-Layer ATDD Suite (`test/support/drivers/`, `test/support/dsl/`, `test/features/`)

### Layer 3 Protocol Driver (`test/support/drivers/workspace_driver.ex`)

Encapsulates all Ash Domain code interfaces, `Xitdb.Ash.Search`, bulk queries, savepoint transactions, and `AshPhoenix.Form` operations.

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.TestDrivers.WorkspaceDriver do
    @moduledoc false

    require Ash.Query

    alias Xitdb.Ash.Search
    alias Xitdb.TestSupport.{
      AppDomain,
      DirectMessage,
      MdmDomain,
      MdmStore,
      MemberProfile,
      TableTalkSeat
    }

    def seed_organization(attrs) do
      MdmDomain.register_organization!(attrs)
    end

    def rename_organization(org, attrs) do
      MdmDomain.rename_organization!(org, attrs)
    end

    def enrol_member(attrs) do
      MdmDomain.enrol_member!(attrs, authorize?: false)
    end

    def list_visible_profiles(actor, opts \\ []) do
      load_fields = Keyword.get(opts, :load, [:display_badge, :sent_message_count])

      MemberProfile
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> maybe_filter_messaged_recipient(opts[:messaged_recipient_id])
      |> Ash.Query.load(load_fields)
      |> Ash.Query.sort(full_name: :asc)
      |> Ash.read!(domain: MdmDomain)
    end

    def edit_profile(target_profile, attrs, actor) do
      MdmDomain.edit_profile(target_profile, attrs, actor: actor)
    end

    def change_member_email(target_profile, new_email, actor) do
      MdmDomain.change_email(target_profile, new_email, actor: actor)
    end

    def increment_profile_view(target_profile, actor) do
      MdmDomain.record_profile_view(target_profile, actor: actor)
    end

    def send_direct_message(sender_id, recipient_id, body) do
      AppDomain.send_message!(%{
        sender_id: sender_id,
        recipient_id: recipient_id,
        body: body
      })
    end

    def bulk_archive_and_prune_messages(recipient_id) do
      %Ash.BulkResult{status: :success, records: archived} =
        DirectMessage
        |> Ash.Query.filter(recipient_id == ^recipient_id and archived? == false)
        |> Ash.bulk_update!(:archive, %{}, domain: AppDomain, return_records?: true)

      %Ash.BulkResult{status: :success, records: destroyed} =
        DirectMessage
        |> Ash.Query.filter(recipient_id == ^recipient_id and archived? == true)
        |> Ash.bulk_destroy!(:destroy, %{}, domain: AppDomain, return_records?: true)

      %{archived_count: length(archived), destroyed_count: length(destroyed)}
    end

    def schedule_event_with_sessions(organizer_id, event_attrs, sessions) do
      event =
        MdmDomain.schedule_event!(Map.put(event_attrs, :organizer_id, organizer_id))

      created_sessions =
        Enum.map(sessions, fn s ->
          MdmDomain.add_session!(Map.put(s, :event_id, event.id))
        end)

      reloaded =
        MdmDomain.get_event!(event.id, load: [:effective_location, :session_count, :total_capacity])

      {reloaded, created_sessions}
    end

    def reserve_seat(session_id, profile_id, seat_number) do
      MdmDomain.reserve_seat(%{
        session_id: session_id,
        profile_id: profile_id,
        seat_number: seat_number
      })
    end

    def cancel_seat!(%TableTalkSeat{} = seat) do
      MdmDomain.cancel_seat!(seat)
    end

    def confirmed_seat_numbers(session_id) do
      TableTalkSeat
      |> Ash.Query.filter(session_id == ^session_id and status == :confirmed)
      |> Ash.read!(domain: MdmDomain)
      |> Enum.map(& &1.seat_number)
      |> Enum.sort()
    end

    def run_outer_tx_with_aborted_nested_savepoint(confirmed_fn, aborted_nested_fn) do
      MdmStore.transact(fn ->
        outer_val = confirmed_fn.()

        {:error, :nested_aborted} =
          MdmStore.transact(fn ->
            _ = aborted_nested_fn.()
            MdmStore.rollback(:nested_aborted)
          end)

        outer_val
      end)
    end

    # Over-fetches BM25 candidates so authorization filtering cannot starve the page, then
    # applies the final limit *after* `Ash.Policy.Authorizer` has filtered the candidate set.
    @search_page_size 20
    @search_overfetch 10

    def search_member_directory(query_text, actor) do
      ranked_ids =
        Search.ids(MemberProfile, query_text, limit: @search_page_size * @search_overfetch)

      if ranked_ids == [] do
        []
      else
        MemberProfile
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(id in ^ranked_ids)
        |> Search.sort_by_rank(ranked_ids)
        |> Ash.Query.limit(@search_page_size)
        |> Ash.read!(domain: MdmDomain)
      end
    end

    def submit_profile_form(params, opts \\ []) do
      form =
        case Keyword.get(opts, :editing) do
          nil ->
            AshPhoenix.Form.for_create(MemberProfile, :submit_application,
              domain: MdmDomain,
              actor: opts[:actor],
              authorize?: Keyword.get(opts, :authorize?, false)
            )

          %MemberProfile{} = existing ->
            AshPhoenix.Form.for_update(existing, :edit_profile,
              domain: MdmDomain,
              actor: opts[:actor]
            )
        end

      validated = AshPhoenix.Form.validate(form, params)
      AshPhoenix.Form.submit(validated, params: params)
    end

    defp maybe_filter_messaged_recipient(query, nil), do: query

    defp maybe_filter_messaged_recipient(query, recipient_id) do
      Ash.Query.filter(query, exists(sent_messages, recipient_id == ^recipient_id))
    end
  end
end
```

### Layer 2 Domain-Specific Language (`test/support/dsl/workspace_dsl.ex`)

Translates readable Layer 1 labels into parallel-safe `ctx.test_id` identities, threads an explicit `%World{}` struct, and stamps `line: __CALLER__.line` on `@then` macros so ExUnit points directly to failing lines in Layer 1.

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.TestDSL.WorkspaceDSL do
    @moduledoc false
    import ExUnit.Assertions

    alias Xitdb.TestDrivers.WorkspaceDriver

    defmodule World do
      @moduledoc false
      defstruct [
        :test_id,
        orgs: %{},
        members: %{},
        events: %{},
        sessions: %{},
        seats: %{},
        last_result: nil,
        search_hits: [],
        bulk_stats: nil
      ]

      @type t :: %__MODULE__{
              test_id: pos_integer(),
              orgs: map(),
              members: map(),
              events: map(),
              sessions: map(),
              seats: map(),
              last_result: term(),
              search_hits: list(),
              bulk_stats: map() | nil
            }
    end

    @spec new_world(map()) :: World.t()
    def new_world(ex_unit_ctx) when is_map(ex_unit_ctx) do
      %World{test_id: Map.get(ex_unit_ctx, :test_id, System.unique_integer([:positive]))}
    end

    # -- @given Steps --

    def firm(%World{} = ctx, label, opts \\ []) do
      domain = unique_domain(ctx, Keyword.get(opts, :domain, "#{slugify(label)}.ca"))
      slug = "#{slugify(label)}-#{ctx.test_id}"

      org =
        WorkspaceDriver.seed_organization(%{
          name: label,
          domain: domain,
          slug: slug,
          mandate: Keyword.get(opts, :mandate)
        })

      %World{ctx | orgs: Map.put(ctx.orgs, label, org)}
    end

    def member(%World{} = ctx, label, opts \\ []) do
      firm_id =
        case Keyword.get(opts, :firm) do
          nil -> nil
          firm_label -> Map.fetch!(ctx.orgs, firm_label).id
        end

      raw_email = Keyword.get(opts, :email, "#{slugify(label)}@allocator.ca")

      profile =
        WorkspaceDriver.enrol_member(%{
          email: unique_email(ctx, raw_email),
          full_name: label,
          headline: Keyword.get(opts, :headline, "Allocator"),
          role: Keyword.get(opts, :role, :member),
          visibility: Keyword.get(opts, :visibility, :public),
          compensation_band: Keyword.get(opts, :compensation_band),
          organization_id: firm_id
        })

      %World{ctx | members: Map.put(ctx.members, label, profile)}
    end

    def direct_message(%World{} = ctx, opts) do
      sender = Map.fetch!(ctx.members, Keyword.fetch!(opts, :from))
      recipient = Map.fetch!(ctx.members, Keyword.fetch!(opts, :to))
      body = Keyword.fetch!(opts, :body)
      _ = WorkspaceDriver.send_direct_message(sender.id, recipient.id, body)
      ctx
    end

    def conference_event(%World{} = ctx, title, opts) do
      organizer = Map.fetch!(ctx.orgs, Keyword.fetch!(opts, :organizer))
      session_specs = Keyword.get(opts, :sessions, [])

      event_attrs = %{
        title: title,
        location_city: Keyword.get(opts, :city),
        location_name: Keyword.fetch!(opts, :venue)
      }

      {event, sessions} =
        WorkspaceDriver.schedule_event_with_sessions(organizer.id, event_attrs, session_specs)

      sessions_by_title =
        Enum.reduce(sessions, ctx.sessions, fn s, acc -> Map.put(acc, s.title, s) end)

      %World{
        ctx
        | events: Map.put(ctx.events, title, event),
          sessions: sessions_by_title
      }
    end

    def confirmed_seat(%World{} = ctx, opts) do
      session = Map.fetch!(ctx.sessions, Keyword.fetch!(opts, :session))
      member = Map.fetch!(ctx.members, Keyword.fetch!(opts, :member))
      seat_no = Keyword.fetch!(opts, :seat)

      {:ok, seat} = WorkspaceDriver.reserve_seat(session.id, member.id, seat_no)
      %World{ctx | seats: Map.put(ctx.seats, {session.title, member.full_name, seat_no}, seat)}
    end

    # -- @upon Steps --

    def updating_profile_headline(%World{} = ctx, target_label, opts) do
      actor = Map.fetch!(ctx.members, Keyword.fetch!(opts, :as))
      target = Map.fetch!(ctx.members, target_label)
      headline = Keyword.fetch!(opts, :to)
      result = WorkspaceDriver.edit_profile(target, %{headline: headline}, actor)
      %World{ctx | last_result: result}
    end

    def changing_member_email(%World{} = ctx, target_label, opts) do
      actor = Map.fetch!(ctx.members, Keyword.fetch!(opts, :as))
      target = Map.fetch!(ctx.members, target_label)
      new_email = unique_email(ctx, Keyword.fetch!(opts, :to))

      case WorkspaceDriver.change_member_email(target, new_email, actor) do
        {:ok, updated} = ok ->
          %World{ctx | members: Map.put(ctx.members, target_label, updated), last_result: ok}

        {:error, _} = err ->
          %World{ctx | last_result: err}
      end
    end

    def viewing_profile_counter(%World{} = ctx, target_label, opts) do
      actor = Map.fetch!(ctx.members, Keyword.fetch!(opts, :as))
      target = Map.fetch!(ctx.members, target_label)
      result = WorkspaceDriver.increment_profile_view(target, actor)
      %World{ctx | last_result: result}
    end

    def cancelling_and_reassigning_seat(%World{} = ctx, opts) do
      session_title = Keyword.fetch!(opts, :session)
      seat_no = Keyword.fetch!(opts, :seat)
      prev_holder = Keyword.fetch!(opts, :from)
      next_holder = Keyword.fetch!(opts, :to)

      existing_seat = Map.fetch!(ctx.seats, {session_title, prev_holder, seat_no})
      _cancelled = WorkspaceDriver.cancel_seat!(existing_seat)

      session = Map.fetch!(ctx.sessions, session_title)
      next_member = Map.fetch!(ctx.members, next_holder)
      result = WorkspaceDriver.reserve_seat(session.id, next_member.id, seat_no)

      %World{ctx | last_result: result}
    end

    def attempting_duplicate_seat(%World{} = ctx, opts) do
      session = Map.fetch!(ctx.sessions, Keyword.fetch!(opts, :session))
      member = Map.fetch!(ctx.members, Keyword.fetch!(opts, :member))
      seat_no = Keyword.fetch!(opts, :seat)

      result = WorkspaceDriver.reserve_seat(session.id, member.id, seat_no)
      %World{ctx | last_result: result}
    end

    def reserving_with_aborted_nested_savepoint(%World{} = ctx, opts) do
      session = Map.fetch!(ctx.sessions, Keyword.fetch!(opts, :session))
      kept_member = Map.fetch!(ctx.members, Keyword.fetch!(opts, :keep_member))
      kept_seat = Keyword.fetch!(opts, :keep_seat)
      rolled_member = Map.fetch!(ctx.members, Keyword.fetch!(opts, :rollback_member))
      rolled_seat = Keyword.fetch!(opts, :rollback_seat)

      {:ok, kept} =
        WorkspaceDriver.run_outer_tx_with_aborted_nested_savepoint(
          fn ->
            {:ok, s} = WorkspaceDriver.reserve_seat(session.id, kept_member.id, kept_seat)
            s
          end,
          fn ->
            {:ok, s} = WorkspaceDriver.reserve_seat(session.id, rolled_member.id, rolled_seat)
            s
          end
        )

      %World{ctx | last_result: {:ok, kept}}
    end

    def renaming_firm(%World{} = ctx, firm_label, opts) do
      org = Map.fetch!(ctx.orgs, firm_label)

      updated =
        WorkspaceDriver.rename_organization(org, %{
          name: Keyword.fetch!(opts, :name),
          mandate: Keyword.fetch!(opts, :mandate)
        })

      %World{ctx | orgs: Map.put(ctx.orgs, firm_label, updated)}
    end

    def searching_directory(%World{} = ctx, query_text, opts) do
      actor = Map.fetch!(ctx.members, Keyword.fetch!(opts, :as))
      hits = WorkspaceDriver.search_member_directory(query_text, actor)
      %World{ctx | search_hits: hits}
    end

    def archiving_and_pruning_inbox(%World{} = ctx, recipient_label) do
      recipient = Map.fetch!(ctx.members, recipient_label)
      stats = WorkspaceDriver.bulk_archive_and_prune_messages(recipient.id)
      %World{ctx | bulk_stats: stats}
    end

    def submitting_membership_form(%World{} = ctx, params) do
      raw_email = Map.fetch!(params, :email)
      scoped_params = Map.put(params, :email, unique_email(ctx, raw_email))
      result = WorkspaceDriver.submit_profile_form(scoped_params)
      %World{ctx | last_result: result}
    end

    # -- @then Steps (`line: __CALLER__.line` attribution) --

    defmacro directory_visible_to(ctx_ast, viewer_label, expected_names, opts \\ []) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        viewer = Map.fetch!(ctx.members, unquote(viewer_label))
        opts = unquote(opts)

        recipient_id =
          case Keyword.get(opts, :who_messaged) do
            nil -> nil
            label -> Map.fetch!(ctx.members, label).id
          end

        profiles =
          WorkspaceDriver.list_visible_profiles(viewer, messaged_recipient_id: recipient_id)

        assert Enum.map(profiles, & &1.full_name) == unquote(expected_names)
        ctx
      end
    end

    defmacro compensation_band_for(ctx_ast, target_label, opts) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        viewer = Map.fetch!(ctx.members, Keyword.fetch!(unquote(opts), :viewed_by))
        expected = Keyword.fetch!(unquote(opts), :is)

        profiles = WorkspaceDriver.list_visible_profiles(viewer, load: [])
        found = Enum.find(profiles, &(&1.full_name == unquote(target_label)))
        assert found != nil

        case expected do
          :redacted -> assert %Ash.ForbiddenField{} = found.compensation_band
          value -> assert found.compensation_band == value
        end

        ctx
      end
    end

    defmacro action_is_forbidden(ctx_ast) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        assert {:error, %Ash.Error.Forbidden{}} = ctx.last_result
        ctx
      end
    end

    defmacro action_fails_with_invalid_field(ctx_ast, expected_field, snippet) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        expected_field = unquote(expected_field)
        assert {:error, error} = ctx.last_result
        assert Exception.message(error) =~ unquote(snippet)

        errors = Map.get(error, :errors, [])

        assert Enum.any?(errors, fn e ->
                 Map.get(e, :field) == expected_field or
                   expected_field in List.wrap(Map.get(e, :fields))
               end)

        ctx
      end
    end

    defmacro profile_summary_matches(ctx_ast, member_label, opts) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        member = Map.fetch!(ctx.members, unquote(member_label))
        opts = unquote(opts)

        [loaded] =
          WorkspaceDriver.list_visible_profiles(member, load: [:display_badge, :sent_message_count])
          |> Enum.filter(&(&1.id == member.id))

        if badge = opts[:badge], do: assert(loaded.display_badge == badge)
        if sent = opts[:sent_messages], do: assert(loaded.sent_message_count == sent)
        if views = opts[:views], do: assert(loaded.view_count == views)
        ctx
      end
    end

    defmacro event_rollup_matches(ctx_ast, event_title, opts) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        event = Map.fetch!(ctx.events, unquote(event_title))
        opts = unquote(opts)

        assert event.effective_location == Keyword.fetch!(opts, :location)
        assert event.session_count == Keyword.fetch!(opts, :sessions)
        assert event.total_capacity == Keyword.fetch!(opts, :total_capacity)
        ctx
      end
    end

    defmacro confirmed_seats_for_session(ctx_ast, session_title, expected_seat_numbers) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        session = Map.fetch!(ctx.sessions, unquote(session_title))

        assert WorkspaceDriver.confirmed_seat_numbers(session.id) ==
                 unquote(expected_seat_numbers)

        ctx
      end
    end

    defmacro search_results_ordered(ctx_ast, expected_names) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        assert Enum.map(ctx.search_hits, & &1.full_name) == unquote(expected_names)
        ctx
      end
    end

    defmacro inbox_prune_counts(ctx_ast, opts) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        opts = unquote(opts)

        assert ctx.bulk_stats == %{
                 archived_count: Keyword.fetch!(opts, :archived),
                 destroyed_count: Keyword.fetch!(opts, :destroyed)
               }

        ctx
      end
    end

    defmacro form_created_member(ctx_ast, expected_name) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        assert {:ok, created} = ctx.last_result
        assert created.full_name == unquote(expected_name)
        %World{ctx | members: Map.put(ctx.members, created.full_name, created)}
      end
    end

    defmacro member_email_has_domain(ctx_ast, member_label, expected_domain) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        member = Map.fetch!(ctx.members, unquote(member_label))
        [loaded] = WorkspaceDriver.list_visible_profiles(member, load: []) |> Enum.filter(&(&1.id == member.id))
        assert String.ends_with?(String.downcase(to_string(loaded.email)), "@" <> unquote(expected_domain))
        ctx
      end
    end

    defmacro form_rejected_field(ctx_ast, field, expected_message) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        assert {:error, form} = ctx.last_result
        errors = AshPhoenix.Form.errors(form)
        assert Enum.any?(errors, fn {f, msg} -> f == unquote(field) and msg =~ unquote(expected_message) end)
        ctx
      end
    end

    # -- Unique Identity Helpers --

    defp unique_domain(%World{test_id: tid}, domain), do: "#{tid}-#{domain}"

    defp unique_email(%World{test_id: tid}, email) do
      case String.split(email, "@", parts: 2) do
        [local, host] -> "#{local}+#{tid}@#{host}"
        [single] -> "#{single}+#{tid}@allocator.ca"
      end
    end

    defp slugify(text) do
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
    end
  end
end
```

### Layer 1 Executable Specifications (`test/features/ash_data_layer_workflows_test.exs`)

Written purely in domain terms with explicit inputs and deterministic assertions:

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Features.AshDataLayerWorkflowsTest do
    use Xitdb.AshCase
    import Xitdb.TestDSL.WorkspaceDSL

    scenario "row-level read filters, field policies, and atomic write authorization enforce member privacy" do
      @given member("Alice Chen",
        headline: "CIO",
        visibility: :public,
        compensation_band: "$500k+"
      )
      @given member("Bob Patel",
        headline: "Managing Director",
        visibility: :private,
        compensation_band: "$400k-$500k"
      )
      @given member("Dana Steward",
        headline: "CAASA Steward",
        role: :steward,
        visibility: :public
      )

      @upon updating_profile_headline("Alice Chen", as: "Bob Patel", to: "Tampered Bio")

      @then action_is_forbidden()
      @then directory_visible_to("Alice Chen", ["Alice Chen", "Dana Steward"])
      @then directory_visible_to("Bob Patel", ["Alice Chen", "Bob Patel", "Dana Steward"])
      @then directory_visible_to("Dana Steward", ["Alice Chen", "Bob Patel", "Dana Steward"])
      @then compensation_band_for("Alice Chen", viewed_by: "Bob Patel", is: :redacted)
      @then compensation_band_for("Alice Chen", viewed_by: "Dana Steward", is: "$500k+")
    end

    scenario "cross-store exists(...) filters, calculations, atomic counters, and bulk inbox pruning" do
      @given member("Elena Rostova", headline: "Head of Private Credit")
      @given member("Marcus Vance", headline: "Pension Allocator")
      @given member("Sofia Laurent", headline: "Endowment Director")
      @given direct_message(from: "Elena Rostova", to: "Marcus Vance", body: "Co-invest deck attached")
      @given direct_message(from: "Elena Rostova", to: "Marcus Vance", body: "Follow-up on Q4 terms")

      @upon viewing_profile_counter("Elena Rostova", as: "Elena Rostova")

      @then profile_summary_matches("Elena Rostova",
        badge: "Elena Rostova (Head of Private Credit)",
        sent_messages: 2,
        views: 1
      )
      @then directory_visible_to("Marcus Vance", ["Elena Rostova"], who_messaged: "Marcus Vance")

      @upon archiving_and_pruning_inbox("Marcus Vance")

      @then profile_summary_matches("Elena Rostova",
        badge: "Elena Rostova (Head of Private Credit)",
        sent_messages: 0,
        views: 1
      )
      @then inbox_prune_counts(archived: 2, destroyed: 2)
      @then directory_visible_to("Marcus Vance", [], who_messaged: "Marcus Vance")
    end

    scenario "nested sessions, portable expression calculations, partial seat identities, and savepoint rollbacks" do
      @given firm("Polar Asset Management", domain: "polar.ca")
      @given conference_event("CAASA Annual Summit",
        organizer: "Polar Asset Management",
        city: nil,
        venue: "Le Westin Montreal",
        sessions: [
          %{title: "Global Macro Roundtable", capacity: 12},
          %{title: "Digital Assets Custody", capacity: 28}
        ]
      )
      @given member("Liam O'Connor", firm: "Polar Asset Management")
      @given member("Nadia Al-Mansoor", firm: "Polar Asset Management")
      @given confirmed_seat(session: "Global Macro Roundtable", member: "Liam O'Connor", seat: 1)

      @upon attempting_duplicate_seat(
        session: "Global Macro Roundtable",
        member: "Nadia Al-Mansoor",
        seat: 1
      )
      @then action_fails_with_invalid_field(:seat_number, "has already been taken")

      @upon cancelling_and_reassigning_seat(
        session: "Global Macro Roundtable",
        seat: 1,
        from: "Liam O'Connor",
        to: "Nadia Al-Mansoor"
      )
      @upon reserving_with_aborted_nested_savepoint(
        session: "Global Macro Roundtable",
        keep_member: "Liam O'Connor",
        keep_seat: 2,
        rollback_member: "Nadia Al-Mansoor",
        rollback_seat: 3
      )

      @then event_rollup_matches("CAASA Annual Summit",
        location: "Le Westin Montreal",
        sessions: 2,
        total_capacity: 40
      )
      @then confirmed_seats_for_session("Global Macro Roundtable", [1, 2])
    end

    scenario "in-Xitdb BM25 + prefix search resolves firm mandates onto profiles without denormalized columns" do
      @given firm("Northleaf Capital",
        domain: "northleaf.ca",
        mandate: "Mid-market infrastructure and private credit secondaries"
      )
      @given firm("Boreal Quant Partners",
        domain: "borealquant.ca",
        mandate: "Systematic statistical arbitrage"
      )
      @given member("Claire Tremblay",
        firm: "Northleaf Capital",
        headline: "Infrastructure Principal"
      )
      @given member("Victor Leung",
        firm: "Boreal Quant Partners",
        headline: "Portfolio Manager"
      )

      @upon searching_directory("infrastr secondar", as: "Claire Tremblay")
      @then search_results_ordered(["Claire Tremblay"])

      @upon renaming_firm("Boreal Quant Partners",
        name: "Boreal Credit Partners",
        mandate: "Senior infrastructure debt and secondaries"
      )
      @upon searching_directory("infrastr secondar", as: "Claire Tremblay")
      @then search_results_ordered(["Claire Tremblay", "Victor Leung"])
    end

    scenario "AshPhoenix.Form and atomic updates enforce corporate-domain validation and persist valid emails" do
      @upon submitting_membership_form(%{
        email: "applicant@gmail.com",
        full_name: "Jordan Lee",
        headline: "Family Office CIO"
      })
      @then form_rejected_field(:email, "must use a corporate domain")

      @upon submitting_membership_form(%{
        email: "jordan@maplefamilyoffice.ca",
        full_name: "Jordan Lee",
        headline: "Family Office CIO"
      })
      @then form_created_member("Jordan Lee")

      @upon changing_member_email("Jordan Lee", as: "Jordan Lee", to: "jordan.personal@gmail.com")
      @then action_fails_with_invalid_field(:email, "must use a corporate domain")
      @then member_email_has_domain("Jordan Lee", "maplefamilyoffice.ca")

      @upon changing_member_email("Jordan Lee", as: "Jordan Lee", to: "j.lee@maplecapital.ca")
      @then member_email_has_domain("Jordan Lee", "maplecapital.ca")
    end
  end
end
```
