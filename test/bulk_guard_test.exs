defmodule AshReferentialActions.BulkGuardTest do
  use ExUnit.Case, async: true

  alias AshReferentialActions.Changes.EnsureTargetLive, as: Guard

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReferentialActions.BulkGuardTest.RestrictTarget
      resource AshReferentialActions.BulkGuardTest.RestrictLocker
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

    relationships do
      restrict_belongs_to :target, RestrictTarget, allow_nil?: false
    end
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
    assert message == ":target 관계의 #{inspect(RestrictTarget)} 대상을 찾을 수 없거나 이미 보관되었습니다."
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
