defmodule AshReferentialActions.Test.GuardGlobalChange do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.context[:global_guard_test] do
      {:direct, target_id} ->
        Ash.Changeset.force_change_attribute(changeset, :target_id, target_id)

      {:before, target_id} ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          Ash.Changeset.force_change_attribute(changeset, :target_id, target_id)
        end)

      {:after, observer} ->
        Ash.Changeset.after_action(changeset, fn _changeset, result ->
          send(observer, :global_after_action_ran)
          {:ok, result}
        end)

      _ ->
        changeset
    end
  end
end

defmodule AshReferentialActions.Test.GuardGlobalAfterBatch do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def batch_change(changesets, _opts, _context), do: changesets

  @impl true
  def after_batch(_results, _opts, _context), do: :ok
end

defmodule AshReferentialActions.Test.GuardGlobalBeforeBatch do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def batch_change(changesets, _opts, _context), do: changesets

  @impl true
  def before_batch(changesets, _opts, _context) do
    Enum.map(changesets, fn changeset ->
      Ash.Changeset.force_change_attribute(
        changeset,
        :target_id,
        changeset.context[:global_batch_target]
      )
    end)
  end
end
