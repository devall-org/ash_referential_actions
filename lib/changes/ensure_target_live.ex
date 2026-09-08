defmodule AshReferentialActions.Changes.EnsureTargetLive do
  @moduledoc """
  Runtime guard added to every create and update action of an
  resource that declares `restrict` or `nilify`: writing the foreign key is rejected
  unless the target exists and is live.

  Without this, a user could be pointed at an already-archived (or, on
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

  Bulk batches without record hooks or managed relationships instead check
  keys together in `before_batch` and `after_batch`, once per relationship,
  domain and tenant. Batches with hooks retain the individual checks so keys
  repaired by a hook are not rejected early. Atomic updates that leave guarded
  keys alone do not run batch callbacks or request result records for this guard.

  The lookup takes a `FOR SHARE` lock on the target row where the data layer
  supports one, so a concurrent archive of that target must wait: either it
  commits first and this check sees the archived row, or this write commits
  first and the archive's own guard sees this user. Without lock support
  (e.g. ETS) the check stays a plain application-level read.

  The target is looked up via the referential relationship's declared
  `read_action` (or the referenced resource's primary read — a verifier rejects a
  filtered primary read as the default), so action-level read filters cannot
  silently hide a live target; archival's global filter still applies, so an
  archived target counts as not live.
  """
  use Ash.Resource.Change

  @batch_mode :ash_referential_actions_target_guard_mode

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.put_context(@batch_mode, :individual)
    |> Ash.Changeset.before_action(&check_changing_keys/1)
    |> Ash.Changeset.after_action(&check_result_keys/2)
  end

  @impl true
  def batch_change(changesets, opts, context) do
    if Enum.any?(changesets, &individual_hooks?/1) do
      Enum.map(changesets, &change(&1, opts, context))
    else
      Enum.map(changesets, &Ash.Changeset.put_context(&1, @batch_mode, :batch))
    end
  end

  # Atomic updates cannot change a guarded key (see atomic/3). In particular,
  # their OriginalDataNotAvailable must not be mistaken for an original nil FK.
  @impl true
  def batch_callbacks?(%Ash.Query{}, _opts, _context), do: false
  def batch_callbacks?(_changesets, _opts, _context), do: true

  @impl true
  def before_batch(changesets, opts, context) do
    # before_transaction and later changes can install hooks after batch_change.
    changesets =
      if Enum.any?(changesets, &(batched?(&1) and individual_hooks?(&1))) do
        Enum.map(changesets, fn changeset ->
          if batched?(changeset), do: change(changeset, opts, context), else: changeset
        end)
      else
        changesets
      end

    errors = batch_errors(changesets, &changing_key/2)

    Enum.with_index(changesets, fn changeset, index ->
      Enum.reduce(ordered_errors(errors, index), changeset, &Ash.Changeset.add_error(&2, &1))
    end)
  end

  @impl true
  def after_batch(changesets_and_results, _opts, _context) do
    errors = batch_errors(changesets_and_results, &result_key/2)

    Enum.with_index(changesets_and_results, fn {_changeset, result}, index ->
      case ordered_errors(errors, index) do
        [] -> {:ok, result}
        [message | _] -> {:error, message}
      end
    end)
  end

  defp ordered_errors(errors, index) do
    errors
    |> Map.get(index, [])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp batched?(changeset), do: changeset.context[@batch_mode] == :batch

  # Moving checks across user hooks can reject values that a hook would repair,
  # or allow subsequent hooks to run before a failure. Keep their original order.
  defp individual_hooks?(changeset) do
    Enum.any?(
      [:before_action, :after_action, :before_transaction, :around_action, :around_transaction],
      &(Map.get(changeset, &1) not in [nil, []])
    ) or changeset.relationships not in [nil, %{}] or later_changes?(changeset)
  end

  # Resource changes run after action changes. Likewise another before_batch
  # can repair keys or install hooks after batch_change has run. In these cases
  # install the original hooks now, at the same position as single-record runs.
  defp later_changes?(changeset) do
    Ash.Resource.Info.changes(changeset.resource, changeset.action_type) != [] or
      Enum.any?((changeset.action && changeset.action.changes) || [], fn
        %{change: {module, _}} when module != __MODULE__ -> module.has_before_batch?()
        _ -> false
      end)
  end

  defp changing_key(changeset, rel) do
    if changeset.valid? and Ash.Changeset.changing_attribute?(changeset, rel.source_attribute) do
      Ash.Changeset.get_attribute(changeset, rel.source_attribute)
    end
  end

  defp result_key({changeset, result}, rel) do
    value = Map.get(result, rel.source_attribute)
    if value != original_value(changeset, rel.source_attribute), do: value
  end

  defp batch_errors(items, key) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      changeset =
        case item do
          {changeset, _result} -> changeset
          changeset -> changeset
        end

      if batched?(changeset) do
        for {rel, rel_index} <- Enum.with_index(guarded_rels(changeset.resource)),
            value = key.(item, rel),
            not is_nil(value),
            do: {{rel, rel_index}, changeset, index, value}
      else
        []
      end
    end)
    |> Enum.group_by(fn {rel, changeset, _, _} ->
      {rel, changeset.domain, changeset.tenant}
    end)
    |> Enum.reduce(%{}, fn {{{rel, rel_index}, _, _}, entries}, errors ->
      {_, changeset, _, _} = hd(entries)
      values = Enum.map(entries, &elem(&1, 3))
      existing = AshReferentialActions.Query.existing_keys(rel, values, changeset, "FOR SHARE")
      type = Ash.Resource.Info.attribute(rel.destination, rel.destination_attribute).type

      # Use type equality for e.g. ci_string and Decimal keys. Plain MapSet
      # membership would incorrectly reject different representations of a key.
      present? =
        if Ash.Type.simple_equality_comparable?(type) do
          keys = MapSet.new(existing, &Ash.Type.to_simple_equality_comparable(type, &1))

          fn value ->
            MapSet.member?(keys, Ash.Type.to_simple_equality_comparable(type, value))
          end
        else
          fn value -> Enum.any?(existing, &Ash.Type.equal?(type, &1, value)) end
        end

      Enum.reduce(entries, errors, fn {_, _, index, value}, errors ->
        if present?.(value) do
          errors
        else
          error = {rel_index, missing_message(rel)}
          Map.update(errors, index, [error], &[error | &1])
        end
      end)
    end)
  end

  # The guard change is appended after the action's own changes, so atomics
  # already contain any foreign-key updates produced by that action. Updates
  # that do not touch a guarded key remain fully atomic.
  @impl true
  def atomic(changeset, _opts, _context) do
    cond do
      touches_guarded_key?(changeset) ->
        {:not_atomic,
         "AshReferentialActions.Changes.EnsureTargetLive must query the referenced target"}

      true ->
        {:ok, changeset}
    end
  end

  defp touches_guarded_key?(changeset) do
    changeset.resource
    |> guarded_rels()
    |> Enum.any?(fn rel ->
      Ash.Changeset.changing_attribute?(changeset, rel.source_attribute) or
        Keyword.has_key?(changeset.atomics, rel.source_attribute)
    end)
  end

  defp guarded_rels(resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&AshReferentialActions.Info.guarded?/1)
  end

  defp check_changing_keys(changeset) do
    changeset.resource
    |> guarded_rels()
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
    |> guarded_rels()
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

      AshReferentialActions.Query.exists?(
        rel,
        [{rel.destination_attribute, value}],
        changeset,
        "FOR SHARE"
      ) ->
        :ok

      true ->
        {:error, missing_message(rel)}
    end
  end

  defp missing_message(rel),
    do: ":#{rel.name} 관계의 #{inspect(rel.destination)} 대상을 찾을 수 없거나 이미 보관되었습니다."
end
