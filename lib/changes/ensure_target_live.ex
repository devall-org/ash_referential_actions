defmodule AshBorrow.Changes.EnsureTargetLive do
  @moduledoc """
  Runtime guard added to every create and update action of an
  `AshBorrow.Borrower` resource: writing a `borrows` foreign key is rejected
  unless the target exists and is live.

  Without this, a borrower could be pointed at an already-archived (or, on
  data layers without foreign keys, missing) target — a ghost reference the
  destroy-side guard can never prevent, since it only fires on the target.

  The check runs in two hooks:

  * `before_action` — catches direct attribute input early, before any work
    is done.
  * `after_action` — re-checks the foreign keys that actually changed on the
    result record, catching values set after `before_action` (notably
    `manage_relationship`, which applies belongs_to keys in its own hooks).
    On transactional data layers the error rolls the write back; on
    non-transactional layers (e.g. ETS) the error is returned but the write
    is not undone — the same caveat as any after-action validation there.

  The target is looked up via the borrows relationship's declared
  `read_action` (or the borrowable's primary read — a verifier rejects a
  filtered primary read as the default), so action-level read filters cannot
  silently hide a live target; archival's global filter still applies, so an
  archived target counts as not live.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&check_changing_keys/1)
    |> Ash.Changeset.after_action(&check_result_keys/2)
  end

  # Updates that provably cannot touch a borrows foreign key stay
  # atomic-compatible. `atomic/3` runs before later changes in the action, so
  # any other change (action-level or global) could still add a foreign key
  # atomic we cannot see yet — returning `{:ok, changeset}` there would skip
  # hook registration entirely and let an atomic bulk update bypass the
  # guard. So the fast path applies only when the key is untouched AND no
  # other changes exist; everything else takes the non-atomic path.
  @impl true
  def atomic(changeset, _opts, _context) do
    cond do
      touches_borrows_key?(changeset) ->
        {:not_atomic, "AshBorrow.Changes.EnsureTargetLive must query the borrowed target"}

      has_other_changes?(changeset) ->
        {:not_atomic,
         "a later change could set a borrows key atomically, " <>
           "which AshBorrow.Changes.EnsureTargetLive must verify"}

      true ->
        {:ok, changeset}
    end
  end

  defp touches_borrows_key?(changeset) do
    changeset.resource
    |> borrows_rels()
    |> Enum.any?(fn rel ->
      Ash.Changeset.changing_attribute?(changeset, rel.source_attribute) or
        Keyword.has_key?(changeset.atomics, rel.source_attribute)
    end)
  end

  defp has_other_changes?(changeset) do
    action_changes =
      case changeset.action do
        %{changes: changes} -> changes
        _ -> []
      end

    global_changes = Ash.Resource.Info.changes(changeset.resource, changeset.action_type)

    (action_changes ++ global_changes)
    |> Enum.any?(fn
      %Ash.Resource.Change{change: {__MODULE__, _}} -> false
      %Ash.Resource.Change{} -> true
      %{} -> false
    end)
  end

  defp borrows_rels(resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&AshBorrow.Info.borrows?/1)
  end

  defp check_changing_keys(changeset) do
    changeset.resource
    |> borrows_rels()
    |> Enum.reduce(changeset, fn rel, changeset ->
      if Ash.Changeset.changing_attribute?(changeset, rel.source_attribute) do
        case verify_target(
               changeset,
               rel,
               Ash.Changeset.get_attribute(changeset, rel.source_attribute)
             ) do
          :ok -> changeset
          {:error, message} -> Ash.Changeset.add_error(changeset, message)
        end
      else
        changeset
      end
    end)
  end

  defp check_result_keys(changeset, result) do
    changeset.resource
    |> borrows_rels()
    |> Enum.reduce_while({:ok, result}, fn rel, {:ok, result} ->
      value = Map.get(result, rel.source_attribute)
      original = original_value(changeset, rel.source_attribute)

      if is_nil(value) or value == original do
        {:cont, {:ok, result}}
      else
        case verify_target(changeset, rel, value) do
          :ok -> {:cont, {:ok, result}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end
    end)
  end

  defp original_value(%{action_type: :create}, _attribute), do: nil
  defp original_value(changeset, attribute), do: Map.get(changeset.data, attribute)

  defp verify_target(changeset, rel, value) do
    cond do
      is_nil(value) ->
        :ok

      AshBorrow.Query.exists?(rel, [{rel.destination_attribute, value}], changeset) ->
        :ok

      true ->
        {:error,
         "cannot borrow via :#{rel.name}: target #{inspect(rel.destination)} " <>
           "does not exist or is not live"}
    end
  end
end
