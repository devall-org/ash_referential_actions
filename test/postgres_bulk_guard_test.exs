defmodule AshReferentialActions.PostgresBulkGuardTest do
  use ExUnit.Case, async: false

  @moduletag :postgres
  @moduletag skip: is_nil(System.get_env("ASH_RA_POSTGRES_PORT"))

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReferentialActions.PostgresBulkGuardTest.Target
      resource AshReferentialActions.PostgresBulkGuardTest.Source
    end
  end

  defmodule Repo do
    use AshPostgres.Repo,
      otp_app: :ash_referential_actions,
      warn_on_missing_ash_functions?: false

    def min_pg_version, do: %Version{major: 17, minor: 0, patch: 0}
  end

  defmodule Target do
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReferentialActions.Archival]

    postgres do
      table "guard_test_targets"
      repo(Repo)
    end

    attributes do
      uuid_primary_key :id
      attribute :tenant_id, :string, public?: true
      attribute :encrypted_info, :string, public?: true
    end

    multitenancy do
      strategy :attribute
      attribute :tenant_id
    end

    actions do
      defaults [:read, :destroy, create: :*]

      read :guard_read do
        argument :channel, :string, default: "default"

        pagination do
          required? true
          offset? true
          default_limit 2
          max_page_size 2
        end
      end
    end

    preparations do
      prepare fn query, _context ->
        if observer = Process.get(:guard_query_observer) do
          send(observer, {:guard_query, query.action.name, query.arguments, query.context})
        end

        if query.context[:ash_referential_actions_guard?] && Process.get(:guard_read_failure) do
          Ash.Query.add_error(query, "guard read failed")
        else
          query
        end
      end
    end

    relationships do
      restrict_has_many :sources, AshReferentialActions.PostgresBulkGuardTest.Source,
        destination_attribute: :target_id
    end
  end

  defmodule ObserveAfterBatch do
    use Ash.Resource.Change

    @impl true
    def batch_change(changesets, _opts, _context), do: changesets

    @impl true
    def after_batch(_results, _opts, context) do
      send(context.source_context.guard_after_batch_observer, :action_after_batch_ran)
      :ok
    end
  end

  defmodule Source do
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReferentialActions.Archival]

    postgres do
      table "guard_test_sources"
      repo(Repo)
    end

    attributes do
      uuid_primary_key :id, public?: true, writable?: true
      attribute :label, :string, public?: true
      attribute :tenant_id, :string, public?: true
    end

    multitenancy do
      strategy :attribute
      attribute :tenant_id
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]

      create :managed do
        accept [:label]
        argument :target, :map, allow_nil?: false
        change manage_relationship(:target, type: :append_and_remove)
      end

      create :early_batch do
        accept [:target_id]
        change AshReferentialActions.Test.GuardGlobalBeforeBatch
      end

      create :with_after_batch do
        accept [:target_id, :label]
        change ObserveAfterBatch
      end
    end

    changes do
      change AshReferentialActions.Test.GuardGlobalChange, on: [:create]
      change AshReferentialActions.Test.GuardGlobalAfterBatch, on: [:create]

      change fn changeset, _context ->
               label = Ash.Changeset.get_attribute(changeset, :label) || "global"
               Ash.Changeset.force_change_attribute(changeset, :label, label)
             end,
             on: [:create]
    end

    relationships do
      restrict_belongs_to :target, Target do
        allow_nil? true
        read_action :guard_read
        read_action_arguments %{channel: "referential"}
        relationship_context %{guard_channel: true}
      end
    end
  end

  setup_all do
    start_supervised!(
      {Repo,
       hostname: "127.0.0.1",
       port: String.to_integer(System.fetch_env!("ASH_RA_POSTGRES_PORT")),
       username: "postgres",
       password: "guard-test",
       database: "guard_test",
       pool_size: 5,
       telemetry_prefix: [:guard_test, :repo],
       log: false}
    )

    # This suite is opt-in and targets a disposable database; see test/README.md.
    Repo.query!(
      "CREATE TABLE IF NOT EXISTS guard_test_targets (id uuid PRIMARY KEY, tenant_id text NOT NULL, archived_at timestamp, encrypted_info text)"
    )

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS guard_test_sources (id uuid PRIMARY KEY, target_id uuid, label text, tenant_id text NOT NULL, archived_at timestamp)"
    )

    Repo.query!("""
    CREATE OR REPLACE FUNCTION guard_test_fill_missing_target() RETURNS trigger AS $$
    BEGIN
      IF NEW.label = 'trigger_missing_target' THEN
        NEW.target_id := '00000000-0000-0000-0000-000000000001';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE OR REPLACE TRIGGER guard_test_fill_missing_target
    BEFORE INSERT ON guard_test_sources
    FOR EACH ROW EXECUTE FUNCTION guard_test_fill_missing_target()
    """)

    :ok
  end

  setup do
    tenant = Ash.UUID.generate()
    handler = {__MODULE__, make_ref()}
    :telemetry.attach(handler, [:guard_test, :repo, :query], &__MODULE__.capture_query/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    %{tenant: tenant}
  end

  def capture_query(_event, _measurements, metadata, pid) do
    send(pid, {:sql, metadata.query})
  end

  test "global changes still allow six guard queries for seven inputs in batches of three", %{
    tenant: tenant
  } do
    target = target(tenant)
    drain_queries()
    result = bulk(List.duplicate(%{target_id: target.id}, 7), tenant, batch_size: 3)
    assert result.status == :success
    assert length(result.records) == 7
    assert Enum.all?(result.records, &(&1.label == "global"))
    queries = guard_queries()
    assert length(queries) == 6
    assert Enum.all?(queries, &String.contains?(&1, "FOR SHARE"))
  end

  test "batch target reads select only the key even with large non-key columns", %{tenant: tenant} do
    live =
      Ash.create!(Target, %{encrypted_info: String.duplicate("x", 100_000)},
        tenant: tenant,
        authorize?: false
      )

    drain_queries()
    assert bulk([%{target_id: live.id}], tenant).status == :success
    queries = guard_queries()
    assert length(queries) == 2

    for query <- queries do
      assert [_, projection] = Regex.run(~r/\ASELECT (.*?) FROM /s, query)
      assert Regex.match?(~r/\A\w+\."id"\z/, projection)
      refute String.contains?(projection, "encrypted_info")
    end
  end

  test "direct FK changes in global change are checked in the batch", %{tenant: tenant} do
    live = target(tenant)
    drain_queries()

    result =
      bulk([%{target_id: Ash.UUID.generate()}], tenant,
        context: %{global_guard_test: {:direct, live.id}}
      )

    assert result.status == :success
    assert [%{target_id: id}] = result.records
    assert id == live.id
    assert length(guard_queries()) == 2
  end

  test "action before_batch runs before the guard and does not require individual checks", %{
    tenant: tenant
  } do
    live = target(tenant)
    drain_queries()

    result =
      Ash.bulk_create(List.duplicate(%{target_id: Ash.UUID.generate()}, 3), Source, :early_batch,
        context: %{global_batch_target: live.id},
        tenant: tenant,
        authorize?: false,
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :success
    assert length(result.records) == 3
    assert Enum.all?(result.records, &(&1.target_id == live.id))
    assert length(guard_queries()) == 2
  end

  test "late global before_action keeps its original position after the guard", %{tenant: tenant} do
    live = target(tenant)

    result =
      bulk([%{target_id: Ash.UUID.generate()}], tenant,
        context: %{global_guard_test: {:before, live.id}}
      )

    assert result.status == :error
    assert inspect(result.errors) =~ "does not exist or is already archived"
    assert stored_count(tenant) == 0
  end

  test "global after_action does not run ahead of a failing result guard", %{tenant: tenant} do
    result =
      bulk([%{label: "trigger_missing_target"}], tenant,
        context: %{global_guard_test: {:after, self()}}
      )

    assert result.status == :error
    refute_receive :global_after_action_ran
    assert stored_count(tenant) == 0
  end

  test "action after_batch does not run ahead of a failing result guard", %{tenant: tenant} do
    result =
      Ash.bulk_create([%{label: "trigger_missing_target"}], Source, :with_after_batch,
        tenant: tenant,
        authorize?: false,
        return_errors?: true,
        context: %{guard_after_batch_observer: self()}
      )

    assert result.status == :error
    assert inspect(result.errors) =~ "does not exist or is already archived"
    assert stored_count(tenant) == 0
    refute_receive :action_after_batch_ran
  end

  test "action after_batch runs after individual guards accept live targets", %{tenant: tenant} do
    live = target(tenant)
    drain_queries()

    result =
      Ash.bulk_create(List.duplicate(%{target_id: live.id}, 3), Source, :with_after_batch,
        tenant: tenant,
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        context: %{guard_after_batch_observer: self()}
      )

    assert result.status == :success
    assert length(result.records) == 3
    assert stored_count(tenant) == 3
    assert length(guard_queries()) == 6
    assert_receive :action_after_batch_ran
  end

  test "distinct keys beyond required pagination are all found", %{tenant: tenant} do
    targets = for _ <- 1..7, do: target(tenant)
    drain_queries()
    result = bulk(Enum.map(targets, &%{target_id: &1.id}), tenant)
    assert result.status == :success
    assert length(result.records) == 7
    assert length(guard_queries()) == 2
  end

  test "guard reads carry declared action arguments and context into preparations", %{
    tenant: tenant
  } do
    assert Ash.Resource.Info.relationship(Source, :target).context == %{guard_channel: true}
    live = target(tenant)
    Process.put(:guard_query_observer, self())
    result = bulk([%{target_id: live.id}], tenant)
    assert result.status == :success

    assert_receive {:guard_query, :guard_read, %{channel: "referential"},
                    %{guard_channel: true, ash_referential_actions_guard?: true}}
  end

  test "before failures affect only invalid records when rollback is disabled", %{tenant: tenant} do
    live = target(tenant)
    archived = target(tenant)
    Ash.destroy!(archived, tenant: tenant, authorize?: false)
    foreign = target(Ash.UUID.generate())

    result =
      bulk(
        [
          %{target_id: live.id},
          %{target_id: archived.id},
          %{target_id: foreign.id},
          %{target_id: Ash.UUID.generate()}
        ],
        tenant,
        rollback_on_error?: false,
        stop_on_error?: false
      )

    assert result.status == :partial_success
    assert result.error_count == 3
    assert length(result.records) == 1
    assert stored_count(tenant) == 1
  end

  test "before failures preserve Ash's partial success semantics inside a batch transaction", %{
    tenant: tenant
  } do
    live = target(tenant)
    result = bulk([%{target_id: live.id}, %{target_id: Ash.UUID.generate()}], tenant)
    assert result.status == :partial_success
    assert stored_count(tenant) == 1
  end

  test "unchanged foreign keys remain atomic without guard queries or returning rows", %{
    tenant: tenant
  } do
    live = target(tenant)
    bulk([%{target_id: live.id}], tenant)
    drain_queries()

    result =
      Ash.bulk_update(Source, :update, %{label: "updated"},
        tenant: tenant,
        authorize?: false,
        strategy: [:atomic],
        return_records?: false,
        return_errors?: true
      )

    assert result.status == :success
    queries = drain_queries()
    assert Enum.all?(queries, &(not String.contains?(&1, "guard_test_targets")))
    update = Enum.find(queries, &String.starts_with?(&1, "UPDATE"))
    assert update
    refute String.contains?(update, "RETURNING")
  end

  test "stream updates batch their changed foreign keys", %{tenant: tenant} do
    old = target(tenant)
    new = target(tenant)
    records = bulk(List.duplicate(%{target_id: old.id}, 7), tenant).records
    drain_queries()

    result =
      Ash.bulk_update(records, :update, %{target_id: new.id},
        tenant: tenant,
        authorize?: false,
        strategy: [:stream],
        batch_size: 3,
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :success
    assert length(result.records) == 7
    assert Enum.all?(result.records, &(&1.target_id == new.id))
    assert length(guard_queries()) == 6
  end

  test "a before_action repairs invalid input before it is checked", %{tenant: tenant} do
    live = target(tenant)

    result =
      bulk([%{target_id: Ash.UUID.generate()}], tenant,
        transform_changeset: fn changeset ->
          Ash.Changeset.before_action(changeset, fn changeset ->
            Ash.Changeset.force_change_attribute(changeset, :target_id, live.id)
          end)
        end
      )

    assert result.status == :success
    assert [%{target_id: id}] = result.records
    assert id == live.id
  end

  test "managed belongs_to keys remain guarded", %{tenant: tenant} do
    live = target(tenant)

    result =
      Ash.bulk_create([%{target: %{id: live.id}}], Source, :managed,
        tenant: tenant,
        authorize?: false,
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :success
    assert [%{target_id: id}] = result.records
    assert id == live.id
  end

  test "an after_action invalid target rolls back the insert", %{tenant: tenant} do
    result =
      bulk([%{}], tenant,
        transform_changeset: fn changeset ->
          Ash.Changeset.after_action(changeset, fn _changeset, result ->
            {:ok, %{result | target_id: Ash.UUID.generate()}}
          end)
        end
      )

    assert result.status == :error
    assert stored_count(tenant) == 0
  end

  test "nil keys execute no guard queries", %{tenant: tenant} do
    result = bulk([%{}, %{target_id: nil}], tenant)
    assert result.status == :success
    assert guard_queries() == []
  end

  test "database-generated invalid keys are caught after insert and roll back the batch", %{
    tenant: tenant
  } do
    result = bulk([%{}, %{label: "trigger_missing_target"}], tenant)
    assert result.status == :error
    assert stored_count(tenant) == 0
  end

  test "after errors with rollback disabled return partial success but retain written rows", %{
    tenant: tenant
  } do
    result =
      bulk([%{}, %{label: "trigger_missing_target"}], tenant,
        rollback_on_error?: false,
        stop_on_error?: false
      )

    assert result.status == :partial_success
    assert result.error_count == 1
    assert length(result.records) == 1
    assert stored_count(tenant) == 2
  end

  test "transaction all rolls back earlier batches on an after error", %{tenant: tenant} do
    result =
      bulk([%{}, %{label: "trigger_missing_target"}], tenant, batch_size: 1, transaction: :all)

    # Ash 3.31's transaction: :all rollback returns status/errors but leaves
    # error_count at its default. Assert both the error and the actual rollback.
    assert result.status == :error
    assert result.errors != []
    assert stored_count(tenant) == 0
  end

  test "skipped upserts only check the input unless skipped records are requested", %{
    tenant: tenant
  } do
    live = target(tenant)
    created = bulk(List.duplicate(%{target_id: live.id}, 7), tenant)
    assert created.status == :success
    inputs = Enum.map(created.records, &%{id: &1.id, target_id: live.id})
    drain_queries()

    result =
      bulk(inputs, tenant,
        upsert?: true,
        upsert_fields: [],
        upsert_condition: false,
        batch_size: 3
      )

    assert result.status == :success, inspect(result.errors)
    assert result.records == []
    assert length(guard_queries()) == 3

    result =
      bulk(inputs, tenant,
        upsert?: true,
        upsert_fields: [],
        upsert_condition: false,
        batch_size: 3,
        return_skipped_upsert?: true
      )

    assert result.status == :success
    assert length(result.records) == 7
    assert length(guard_queries()) == 6
  end

  test "guard query errors remain read errors rather than missing-target errors", %{
    tenant: tenant
  } do
    live = target(tenant)
    Process.put(:guard_read_failure, true)
    error = assert_raise Ash.Error.Unknown, fn -> bulk([%{target_id: live.id}], tenant) end
    assert Exception.message(error) =~ "guard read failed"
    refute Exception.message(error) =~ "does not exist or is already archived"
    assert stored_count(tenant) == 0
  end

  test "every target row remains share-locked until the source transaction commits", %{
    tenant: tenant
  } do
    targets = for _ <- 1..2, do: target(tenant)
    parent = self()

    writer =
      Task.async(fn ->
        Repo.transaction(fn ->
          result = bulk(Enum.map(targets, &%{target_id: &1.id}), tenant, transaction: false)
          send(parent, {:inserted, result.status})

          receive do
            :commit -> :ok
          after
            5_000 -> raise "test transaction was not released"
          end
        end)
      end)

    on_exit(fn -> send(writer.pid, :commit) end)
    assert_receive {:inserted, :success}, 2_000

    for target <- targets do
      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               Repo.query(
                 "SELECT id FROM guard_test_targets WHERE id::text = $1 FOR UPDATE NOWAIT",
                 [target.id]
               )
    end

    send(writer.pid, :commit)
    assert {:ok, :ok} = Task.await(writer)

    for target <- targets do
      assert {:error, error} = Ash.destroy(target, tenant: tenant, authorize?: false)
      assert Exception.message(error) =~ "still restricted"
    end
  end

  test "5000 inputs execute 100 guard queries with batch size 100", %{tenant: tenant} do
    live = target(tenant)
    drain_queries()

    {elapsed, result} =
      :timer.tc(fn ->
        bulk(List.duplicate(%{target_id: live.id}, 5_000), tenant, return_records?: false)
      end)

    assert result.status == :success
    assert stored_count(tenant) == 5_000
    assert length(guard_queries()) == 100

    IO.puts(
      "5000-record guard benchmark: #{Float.round(elapsed / 1_000_000, 3)}s, 100 guard queries"
    )
  end

  defp target(tenant), do: Ash.create!(Target, %{}, tenant: tenant, authorize?: false)

  defp bulk(inputs, tenant, opts \\ []) do
    Ash.bulk_create(
      inputs,
      Source,
      :create,
      Keyword.merge(
        [
          tenant: tenant,
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          batch_size: 100
        ],
        opts
      )
    )
  end

  defp stored_count(tenant) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM guard_test_sources WHERE tenant_id = $1", [tenant])

    count
  end

  defp guard_queries do
    Enum.filter(
      drain_queries(),
      &(String.starts_with?(&1, "SELECT") and
          String.contains?(&1, "guard_test_targets"))
    )
  end

  defp drain_queries(acc \\ []) do
    receive do
      {:sql, query} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
