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
  domain and tenant. When only result hooks prevent full batching, the input
  keys are checked together inside a transaction and result keys retain their
  individual `after_action` checks. Batches with only `before_action` hooks keep
  individual input checks and group the result checks. A tail hook on every
  changeset confirms that no result hooks were added at runtime; one unsafe row
  keeps result checks individual for the entire batch. These partial batch paths
  require transactional target locks. Other hooks retain individual checks so
  keys are checked at the original hook position. Global changes that only modify
  attributes do not disable batching; global `before_batch` callbacks still
  require individual checks because they run after this guard's `before_batch`.
  Action `after_batch` callbacks also require individual checks so they cannot
  run before a failing result guard.
  Atomic updates that leave guarded keys alone do not run batch callbacks or
  request result records for this guard.

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
  @result_batch :ash_referential_actions_result_guard_batch

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.put_context(@batch_mode, :individual)
    |> Ash.Changeset.before_action(&check_changing_keys/1)
    |> Ash.Changeset.after_action(&check_result_keys/2)
  end

  @impl true
  def batch_change(changesets, opts, context) do
    # Reserve the original hook positions before resource-level changes run.
    # before_batch removes these hooks only after proving this batch can use
    # grouped checks. Late hooks therefore never move ahead of our guard.
    changesets = Enum.map(changesets, &change(&1, opts, context))

    if Enum.any?(changesets, &individual_hooks?/1) do
      changesets
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
  def before_batch(changesets, _opts, _context) do
    # Global changes have now run, so their direct attribute writes are visible.
    # If they installed hooks, retain any guard hook whose position matters.
    individual? = Enum.any?(changesets, &individual_hooks?/1)

    batch_before? =
      individual? and changesets != [] and
        Enum.all?(changesets, &can_hold_guard_locks?/1) and
        Enum.all?(changesets, &batch_before_safe?/1)

    batch_after? =
      individual? and not batch_before? and changesets != [] and
        Enum.all?(changesets, &can_hold_guard_locks?/1) and
        Enum.all?(changesets, &batch_after_safe?/1)

    result_batch =
      if batch_after? do
        # Shared only by this batch, and garbage-collected with its changesets.
        # Slot 1 counts unfinished before_action tails; slot 2 disables deferral.
        state = :atomics.new(2, [])
        :atomics.put(state, 1, length(changesets))
        state
      end

    changesets =
      Enum.map(changesets, fn changeset ->
        cond do
          batch_before? ->
            changeset
            |> Ash.Changeset.put_context(@batch_mode, :batch_before)
            |> without_before_guard_hook()

          batch_after? ->
            changeset
            |> Ash.Changeset.put_context(@batch_mode, :batch_after)
            |> Ash.Changeset.put_context(@result_batch, result_batch)
            |> Ash.Changeset.before_action(&prepare_batch_result_check/1)

          individual? ->
            Ash.Changeset.put_context(changeset, @batch_mode, :individual)

          batched?(changeset) ->
            without_guard_hooks(changeset)

          true ->
            changeset
        end
      end)

    errors = batch_errors(changesets, &changing_key/2, &batched_before?/1)

    Enum.with_index(changesets, fn changeset, index ->
      Enum.reduce(ordered_errors(errors, index), changeset, &Ash.Changeset.add_error(&2, &1))
    end)
  end

  @impl true
  def after_batch(changesets_and_results, _opts, _context) do
    errors = batch_errors(changesets_and_results, &result_key/2, &batched_after?/1)

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
  defp batched_before?(changeset), do: changeset.context[@batch_mode] in [:batch, :batch_before]

  defp batched_after?(changeset) do
    case changeset.context[@batch_mode] do
      :batch ->
        true

      :batch_after ->
        state = changeset.context[@result_batch]

        :atomics.get(state, 1) == 0 and :atomics.get(state, 2) == 0 and
          batch_after_safe?(changeset) and can_hold_guard_locks?(changeset)

      _ ->
        false
    end
  end

  # Ash runs every row's before_action hooks before running any result hooks.
  # Check at the tail, since a user hook can install result hooks dynamically.
  # One unsafe row keeps every result guard in its original position, including
  # guards on earlier rows whose failures must prevent that row's side effects.
  # If a hook fails before this tail runs, the unfinished count prevents deferral.
  defp prepare_batch_result_check(changeset) do
    state = changeset.context[@result_batch]

    unless batch_after_safe?(changeset) and can_hold_guard_locks?(changeset) do
      :atomics.put(state, 2, 1)
    end

    :atomics.sub(state, 1, 1)
    changeset
  end

  # Moving checks across user hooks can reject values that a hook would repair,
  # or allow subsequent hooks to run before a failure. Keep their original order.
  defp individual_hooks?(changeset) do
    changeset = without_guard_hooks(changeset)

    Enum.any?(
      [:before_action, :after_action, :before_transaction, :around_action, :around_transaction],
      &(Map.get(changeset, &1) not in [nil, []])
    ) or changeset.relationships not in [nil, %{}] or action_after_batch_hooks?(changeset) or
      later_batch_hooks?(changeset)
  end

  # All before_action hooks for the batch run before any result hooks. With no
  # earlier record hooks or later before_batch callbacks, moving only the input
  # lookup to before_batch preserves its position relative to user hooks.
  # Keep the result hook because after_batch can run after user callbacks.
  defp batch_before_safe?(changeset) do
    changeset = without_guard_hooks(changeset)

    Enum.all?(
      [:before_action, :before_transaction, :around_action, :around_transaction],
      &(Map.get(changeset, &1) in [nil, []])
    ) and changeset.relationships in [nil, %{}] and not later_batch_hooks?(changeset)
  end

  defp batch_after_safe?(changeset) do
    changeset = without_guard_hooks(changeset)

    # Manual actions can replace changesets after the before_action tail runs.
    Enum.all?(
      [
        :after_action,
        :before_transaction,
        :around_action,
        :around_transaction,
        :authorize_results
      ],
      &(Map.get(changeset, &1) in [nil, []])
    ) and changeset.relationships in [nil, %{}] and is_nil(changeset.action.manual) and
      not action_after_batch_hooks?(changeset) and not later_batch_hooks?(changeset)
  end

  defp can_hold_guard_locks?(changeset) do
    Ash.DataLayer.in_transaction?(changeset.resource) and
      Enum.all?(guarded_rels(changeset.resource), fn rel ->
        Ash.DataLayer.in_transaction?(rel.destination) and
          Ash.DataLayer.data_layer_can?(rel.destination, {:lock, "FOR SHARE"})
      end)
  end

  defp without_before_guard_hook(changeset) do
    %{
      changeset
      | before_action:
          Enum.reject(changeset.before_action, fn hook -> hook == (&check_changing_keys/1) end)
    }
  end

  defp without_guard_hooks(changeset) do
    %{
      changeset
      | before_action:
          Enum.reject(changeset.before_action, fn hook -> hook == (&check_changing_keys/1) end),
        after_action:
          Enum.reject(changeset.after_action, fn hook -> hook == (&check_result_keys/2) end)
    }
  end

  # Action after_batch callbacks precede this guard's after_batch. Keep the
  # result check in after_action so a failure still prevents those callbacks.
  defp action_after_batch_hooks?(%{action: %{changes: changes}}) do
    Enum.any?(changes, fn
      %{change: {module, _}} when module != __MODULE__ ->
        module.has_batch_change?() and module.has_after_batch?()

      _ ->
        false
    end)
  end

  defp action_after_batch_hooks?(_changeset), do: false

  # Action before_batch callbacks precede this guard, but resource-level ones
  # run after it. Their writes/hooks are not visible during our recheck, so keep
  # individual checks for that case. Ordinary global changes are batch-safe.
  defp later_batch_hooks?(changeset) do
    changeset.resource
    |> Ash.Resource.Info.changes(changeset.action_type)
    |> Enum.any?(fn
      %{change: {module, _}} when module != __MODULE__ ->
        module.has_batch_change?() and module.has_before_batch?()

      _ ->
        false
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

  defp batch_errors(items, key, batched?) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      changeset =
        case item do
          {changeset, _result} -> changeset
          changeset -> changeset
        end

      if batched?.(changeset) do
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
    if batched_after?(changeset) do
      {:ok, result}
    else
      check_individual_result_keys(changeset, result)
    end
  end

  defp check_individual_result_keys(changeset, result) do
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
    do:
      "The #{inspect(rel.destination)} target for relationship :#{rel.name} does not exist or is already archived."
end
