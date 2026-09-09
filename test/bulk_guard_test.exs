defmodule AshReferentialActions.BulkGuardTest do
  use ExUnit.Case, async: true

  alias AshReferentialActions.Changes.EnsureTargetLive, as: Guard

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReferentialActions.BulkGuardTest.RestrictTarget
      resource AshReferentialActions.BulkGuardTest.RestrictLocker
      resource AshReferentialActions.BulkGuardTest.LateBatchLocker
    end
  end

  defmodule RestrictTarget do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReferentialActions.Archival]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      restrict_has_many :lockers, AshReferentialActions.BulkGuardTest.RestrictLocker,
        destination_attribute: :target_id

      restrict_has_many :late_lockers, AshReferentialActions.BulkGuardTest.LateBatchLocker,
        destination_attribute: :target_id
    end
  end

  defmodule RestrictLocker do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReferentialActions.Archival]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end

    changes do
      change AshReferentialActions.Test.GuardGlobalChange, on: [:create]
    end

    relationships do
      restrict_belongs_to :target, RestrictTarget, allow_nil?: false
    end
  end

  defmodule LateBatchLocker do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReferentialActions.Archival]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: :*]
    end

    changes do
      change AshReferentialActions.Test.GuardGlobalBeforeBatch, on: [:create]
    end

    relationships do
      restrict_belongs_to :target, RestrictTarget, allow_nil?: false
    end
  end

  test "global before_batch repairs the input before the original guard executes" do
    live = create_target()

    result =
      Ash.bulk_create([%{target_id: Ash.UUID.generate()}], LateBatchLocker, :create,
        context: %{global_batch_target: live.id},
        authorize?: false,
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :success
    assert [%{target_id: id}] = result.records
    assert id == live.id
  end

  test "late global before_action does not move ahead of the original guard" do
    live = create_target()

    result =
      Ash.bulk_create([%{target_id: Ash.UUID.generate()}], RestrictLocker, :create,
        context: %{global_guard_test: {:before, live.id}},
        authorize?: false,
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :error
    assert inspect(result.errors) =~ "does not exist or is already archived"
  end

  test "bulk create accepts live targets and rejects only missing/archived inputs without rollback" do
    live = create_target()
    archived = create_target()
    Ash.destroy!(archived, authorize?: false)

    result =
      Ash.bulk_create(
        [%{target_id: live.id}, %{target_id: archived.id}, %{target_id: Ash.UUID.generate()}],
        RestrictLocker,
        :create,
        authorize?: false,
        transaction: false,
        stop_on_error?: false,
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :partial_success
    assert result.error_count == 2
    assert [%{target_id: target_id}] = result.records
    assert target_id == live.id
  end

  test "single and stream bulk updates still reject a missing target" do
    live = create_target()
    record = Ash.create!(RestrictLocker, %{target_id: live.id}, authorize?: false)
    missing = Ash.UUID.generate()

    assert {:error, _} = Ash.update(record, %{target_id: missing}, authorize?: false)

    result =
      Ash.bulk_update([record], :update, %{target_id: missing},
        strategy: [:stream],
        authorize?: false,
        return_errors?: true
      )

    assert result.status == :error
    assert result.error_count == 1
  end

  test "a before_action can repair a missing input before the guard runs" do
    target = create_target()

    result =
      Ash.bulk_create([%{target_id: Ash.UUID.generate()}], RestrictLocker, :create,
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        transform_changeset: fn changeset ->
          Ash.Changeset.before_action(changeset, fn changeset ->
            Ash.Changeset.force_change_attribute(changeset, :target_id, target.id)
          end)
        end
      )

    assert result.status == :success
    assert [%{target_id: id}] = result.records
    assert id == target.id
  end

  test "after_batch validates result keys which were absent from input" do
    changeset = %{Ash.Changeset.new(RestrictLocker) | action_type: :create}
    [changeset] = Guard.batch_change([changeset], [], %{})
    result = struct(RestrictLocker, id: Ash.UUID.generate(), target_id: Ash.UUID.generate())
    assert [{:error, message}] = Guard.after_batch([{changeset, result}], [], %{})

    assert message ==
             "The #{inspect(RestrictTarget)} target for relationship :target does not exist or is already archived."
  end

  test "atomic query updates opt out of batch callbacks" do
    refute Guard.batch_callbacks?(Ash.Query.new(RestrictLocker), [], %{})
  end

  test "empty batches and nil keys need no target reads" do
    assert Guard.before_batch([], [], %{}) == []
    assert Guard.after_batch([], [], %{}) == []
    changeset = Ash.Changeset.for_create(RestrictLocker, :create, %{})
    rel = Ash.Resource.Info.relationship(RestrictLocker, :target)
    assert AshReferentialActions.Query.existing_keys(rel, [nil], changeset, "FOR SHARE") == []
  end

  defp create_target, do: Ash.create!(RestrictTarget, %{}, authorize?: false)
end
