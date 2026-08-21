defmodule AshOwnership.Verifiers.LockedByConsistency do
  @moduledoc false
  # Cross-checks between this resource's `locks` edges and the reverse
  # declarations on their destinations.
  #
  # All cross-module checks live on the using side so that compile-time
  # module dependencies flow in one direction only (user -> used),
  # mirroring how AshCascadeArchival verifies parents from the child side.
  # A `locked_by` that points at a module which never locks anything is
  # therefore not detectable; this is documented as a limitation.
  #
  # For each `locks` edge to destination D:
  #
  #   a. Every `locked_by` on D that points at this resource must match one
  #      of this resource's `locks` edges on BOTH key attributes (no lying
  #      or mis-wired reverse declarations).
  #   b. A plain `has_many` on D that traverses a locks foreign key of this
  #      resource must be declared with `locked_by` instead.
  #   c. D must declare a matching `locked_by` back to this resource, so
  #      the destroy guard can enumerate its users — on any data layer,
  #      archival or not.
  #   d. The read actions the guards will query through must be usable: an
  #      explicitly declared `read_action` must exist, and where the default
  #      (the primary read) is used it must carry no action-level
  #      filters/preparations — those hide physically live rows from the
  #      guards. A filtered primary read forces an explicit `read_action`.
  use Spark.Dsl.Verifier

  alias Ash.Resource.Relationships.HasMany
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    locks_rels =
      dsl_state
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&AshOwnership.Info.locks?/1)
      |> Enum.filter(&AshOwnership.Info.enabled?(&1.destination))

    locks_rels
    |> Enum.group_by(& &1.destination)
    |> Enum.reduce_while(:ok, fn {destination, rels}, :ok ->
      case verify_destination(dsl_state, module, destination, rels) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp verify_destination(dsl_state, module, destination, locks_rels) do
    destination_rels = Ash.Resource.Info.relationships(destination)

    reverse_rels =
      Enum.filter(destination_rels, fn rel ->
        AshOwnership.Info.locked_by?(rel) and rel.destination == module
      end)

    with :ok <- verify_reverse_authenticity(module, destination, locks_rels, reverse_rels),
         :ok <-
           verify_plain_has_many(
             module,
             destination,
             locks_rels,
             destination_rels,
             reverse_rels
           ),
         :ok <- verify_has_reverse(module, destination, locks_rels, reverse_rels) do
      verify_guard_channels(dsl_state, module, destination, locks_rels, reverse_rels)
    end
  end

  # The target-live guard queries D through the locks edge; the destroy
  # guard queries this resource through D's locked_by. Both channels'
  # effective read actions are checked here, on the using side, keeping
  # compile-time dependencies one-directional.
  defp verify_guard_channels(dsl_state, module, destination, locks_rels, reverse_rels) do
    Enum.reduce_while(locks_rels, :ok, fn locks_rel, :ok ->
      matching = Enum.filter(reverse_rels, &matching_pair?(&1, locks_rel))

      with :ok <- verify_channel(module, locks_rel, destination, destination, locks_rel.name),
           :ok <- verify_reverse_channels(module, matching, dsl_state, locks_rel) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # The destroy guard queries every `locked_by` and blocks if any reports a
  # user, so several reverse declarations over one foreign key are an OR.
  # Each must resolve to a real read action (an unresolvable one crashes the
  # guard), and at least one must be unfiltered — a union of filtered views is
  # not a proof that no user is left.
  defp verify_reverse_channels(module, reverse_rels, dsl_state, locks_rel) do
    resolved =
      Enum.map(reverse_rels, fn rel -> {rel, resolve_channel_action(rel, dsl_state, module)} end)

    unresolved =
      Enum.find_value(resolved, fn
        {_rel, {:error, message}} -> message
        {_rel, {:ok, _action}} -> nil
      end)

    clean? =
      Enum.any?(resolved, fn
        {_rel, {:ok, action}} -> not AshOwnership.Query.unclean_read_action?(action)
        {_rel, {:error, _}} -> false
      end)

    cond do
      unresolved ->
        {:error, channel_error(module, locks_rel.name, unresolved)}

      clean? ->
        :ok

      true ->
        {:error,
         channel_error(module, locks_rel.name, """
         Every `locked_by` on #{inspect(locks_rel.destination)} matching \
         `locks :#{locks_rel.name}` reads #{inspect(module)} through a read action that \
         carries filters, preparations, or required arguments: \
         #{Enum.map_join(resolved, ", ", fn {rel, {:ok, action}} -> "#{rel_label(rel)} -> :#{action.name}" end)}.

         The destroy guard ORs these channels together, so a union of filtered views can \
         miss a live user. Add one unfiltered channel:

           locked_by :all_#{suggest_name(module)}, #{inspect(module)}

         Note that other extensions may assign `read_action` for you — check whether one \
         did, and opt that relationship out of it if so.
         """)}
    end
  end

  # `queried` is what the guard will read through `rel`: the destination
  # module for the locks edge, this resource's dsl_state for the reverse.
  defp verify_channel(module, rel, queried, queried_name, path_name) do
    case resolve_channel_action(rel, queried, queried_name) do
      {:ok, action} ->
        if AshOwnership.Query.unclean_read_action?(action) do
          {:error,
           channel_error(module, path_name, """
           The read action `:#{action.name}` of #{inspect(queried_name)}, which the \
           guard for `#{rel_label(rel)}` queries through, carries filters, \
           preparations, or required arguments. Those would hide physically live \
           rows from the guard.

           Point the relationship at a read action suitable for existence checks:

             #{rel_label(rel)} do
               read_action :name_of_unfiltered_read
             end

           Note that other extensions may assign `read_action` for you — check \
           whether one did, and opt this relationship out of it if so.
           """)}
        else
          :ok
        end

      {:error, message} ->
        {:error, channel_error(module, path_name, message)}
    end
  end

  defp resolve_channel_action(rel, queried, queried_name) do
    case rel.read_action do
      nil ->
        case Ash.Resource.Info.primary_action(queried, :read) do
          nil ->
            {:error,
             """
             #{inspect(queried_name)} has no primary read action, so the guard for \
             `#{rel_label(rel)}` has nothing to query through.

             Add a read action, or declare `read_action` on `#{rel_label(rel)}`.
             """}

          action ->
            {:ok, action}
        end

      name ->
        case Ash.Resource.Info.action(queried, name) do
          %{type: :read} = action ->
            {:ok, action}

          _ ->
            {:error,
             """
             `#{rel_label(rel)}` declares `read_action :#{name}`, but the queried \
             resource has no read action with that name.
             """}
        end
    end
  end

  defp rel_label(rel) do
    kind = if AshOwnership.Info.locks?(rel), do: "locks", else: "locked_by"
    "#{kind} :#{rel.name}"
  end

  defp channel_error(module, path_name, message) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:relationships, path_name],
      message: message
    )
  end

  defp matching_pair?(reverse_rel, locks_rel),
    do: AshOwnership.Info.reverse_of?(reverse_rel, locks_rel)

  defp verify_reverse_authenticity(module, destination, locks_rels, reverse_rels) do
    reverse_rels
    |> Enum.find(fn reverse_rel ->
      not Enum.any?(locks_rels, &matching_pair?(reverse_rel, &1))
    end)
    |> case do
      nil ->
        :ok

      reverse_rel ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:relationships],
           message: """
           #{inspect(destination)} declares `locked_by :#{reverse_rel.name}` pointing at \
           #{inspect(module)} via #{inspect(reverse_rel.source_attribute)} -> \
           #{inspect(reverse_rel.destination_attribute)}, but #{inspect(module)} has no \
           matching `locks` relationship on that attribute pair.
           """
         )}
    end
  end

  defp verify_has_reverse(module, destination, locks_rels, reverse_rels) do
    locks_rels
    |> Enum.find(fn locks_rel ->
      not Enum.any?(reverse_rels, &matching_pair?(&1, locks_rel))
    end)
    |> case do
      nil ->
        :ok

      locks_rel ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:relationships, locks_rel.name],
           message: """
           #{inspect(destination)} has the AshOwnership extension, but declares no `locked_by` matching \
           `locks :#{locks_rel.name}`.

           The destroy guard on #{inspect(destination)} must be able to enumerate every \
           user. Add to #{inspect(destination)}:

             locked_by :#{suggest_name(module)}, #{inspect(module)}
           """
         )}
    end
  end

  # A plain `has_many` over a locks foreign key is only a problem when it is
  # the *only* reverse declaration: the guard would then have no channel. Once
  # a matching `locked_by` exists, further plain views over the same key are
  # ordinary derived relationships (filtered lists and the like) and are left
  # alone — `locked_by` deliberately accepts no `filter`, so they could not
  # be expressed as one anyway.
  defp verify_plain_has_many(module, destination, locks_rels, destination_rels, reverse_rels) do
    unguarded =
      Enum.reject(locks_rels, fn locks_rel ->
        Enum.any?(reverse_rels, &matching_pair?(&1, locks_rel))
      end)

    destination_rels
    |> Enum.find(fn
      %HasMany{} = rel ->
        not AshOwnership.Info.locked_by?(rel) and rel.destination == module and
          Enum.any?(unguarded, &matching_pair?(rel, &1))

      %{} ->
        false
    end)
    |> case do
      nil ->
        :ok

      rel ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:relationships],
           message: """
           #{inspect(destination)} declares `has_many :#{rel.name}` traversing the locks \
           foreign key #{inspect(rel.destination_attribute)} of #{inspect(module)}.

           The reverse side of a locks edge must be declared with `locked_by`:

             locked_by :#{rel.name}, #{inspect(module)}
           """
         )}
    end
  end

  defp suggest_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> Kernel.<>("s")
  end
end
