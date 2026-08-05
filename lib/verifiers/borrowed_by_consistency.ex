defmodule AshBorrow.Verifiers.BorrowedByConsistency do
  @moduledoc false
  # Cross-checks between this resource's `borrows` edges and the reverse
  # declarations on their borrowable destinations.
  #
  # All cross-module checks live on the borrower side so that compile-time
  # module dependencies flow in one direction only (borrower -> borrowable),
  # mirroring how AshCascadeArchival verifies parents from the child side.
  # A `borrowed_by` that points at a module which never borrows anything is
  # therefore not detectable; this is documented as a limitation.
  #
  # For each `borrows` edge to destination D:
  #
  #   a. Every `borrowed_by` on D that points at this resource must match one
  #      of this resource's `borrows` edges on BOTH key attributes (no lying
  #      or mis-wired reverse declarations).
  #   b. A plain `has_many` on D that traverses a borrows foreign key of this
  #      resource must be declared with `borrowed_by` instead.
  #   c. D must declare a matching `borrowed_by` back to this resource, so
  #      the destroy guard can enumerate its borrowers — on any data layer,
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

    borrows_rels =
      dsl_state
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&AshBorrow.Info.borrows?/1)
      |> Enum.filter(&AshBorrow.Info.borrowable?(&1.destination))

    borrows_rels
    |> Enum.group_by(& &1.destination)
    |> Enum.reduce_while(:ok, fn {destination, rels}, :ok ->
      case verify_destination(dsl_state, module, destination, rels) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp verify_destination(dsl_state, module, destination, borrows_rels) do
    destination_rels = Ash.Resource.Info.relationships(destination)

    reverse_rels =
      Enum.filter(destination_rels, fn rel ->
        AshBorrow.Info.borrowed_by?(rel) and rel.destination == module
      end)

    with :ok <- verify_reverse_authenticity(module, destination, borrows_rels, reverse_rels),
         :ok <- verify_plain_has_many(module, destination, borrows_rels, destination_rels),
         :ok <- verify_has_reverse(module, destination, borrows_rels, reverse_rels) do
      verify_guard_channels(dsl_state, module, destination, borrows_rels, reverse_rels)
    end
  end

  # The target-live guard queries D through the borrows edge; the destroy
  # guard queries this resource through D's borrowed_by. Both channels'
  # effective read actions are checked here, on the borrower side, keeping
  # compile-time dependencies one-directional.
  defp verify_guard_channels(dsl_state, module, destination, borrows_rels, reverse_rels) do
    Enum.reduce_while(borrows_rels, :ok, fn borrows_rel, :ok ->
      reverse_rel = Enum.find(reverse_rels, &matching_pair?(&1, borrows_rel))

      with :ok <- verify_channel(module, borrows_rel, destination, destination, borrows_rel.name),
           :ok <- verify_channel(module, reverse_rel, dsl_state, module, borrows_rel.name) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # `queried` is what the guard will read through `rel`: the destination
  # module for the borrows edge, this resource's dsl_state for the reverse.
  defp verify_channel(module, rel, queried, queried_name, path_name) do
    case rel.read_action do
      nil ->
        primary = Ash.Resource.Info.primary_action(queried, :read)

        cond do
          primary == nil ->
            {:error,
             channel_error(module, path_name, """
             #{inspect(queried_name)} has no primary read action, so the guard for \
             `#{rel_label(rel)}` has nothing to query through.

             Add a read action, or declare `read_action` on `#{rel_label(rel)}`.
             """)}

          AshBorrow.Query.unclean_read_action?(primary) ->
            {:error,
             channel_error(module, path_name, """
             The primary read action of #{inspect(queried_name)} carries filters, \
             preparations, or required arguments, which would hide physically live \
             rows from the guard querying through `#{rel_label(rel)}`.

             Declare an explicit read action suitable for existence checks:

               #{rel_label(rel)} do
                 read_action :name_of_unfiltered_read
               end
             """)}

          true ->
            :ok
        end

      name ->
        action = Ash.Resource.Info.action(queried, name)

        if action && action.type == :read do
          :ok
        else
          {:error,
           channel_error(module, path_name, """
           `#{rel_label(rel)}` declares `read_action :#{name}`, but \
           #{inspect(queried_name)} has no read action with that name.
           """)}
        end
    end
  end

  defp rel_label(rel) do
    kind = if AshBorrow.Info.borrows?(rel), do: "borrows", else: "borrowed_by"
    "#{kind} :#{rel.name}"
  end

  defp channel_error(module, path_name, message) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:relationships, path_name],
      message: message
    )
  end

  # A reverse matches a borrows edge only when both sides of the key pair
  # line up: the reverse queries borrower rows by `destination_attribute`
  # (the borrows FK) starting from its own `source_attribute` (the borrowed
  # key). Checking only one side would let a mis-wired reverse compile and
  # feed the destroy guard a query that never finds real borrowers.
  defp matching_pair?(reverse_rel, borrows_rel) do
    reverse_rel.destination_attribute == borrows_rel.source_attribute and
      reverse_rel.source_attribute == borrows_rel.destination_attribute
  end

  defp verify_reverse_authenticity(module, destination, borrows_rels, reverse_rels) do
    reverse_rels
    |> Enum.find(fn reverse_rel ->
      not Enum.any?(borrows_rels, &matching_pair?(reverse_rel, &1))
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
           #{inspect(destination)} declares `borrowed_by :#{reverse_rel.name}` pointing at \
           #{inspect(module)} via #{inspect(reverse_rel.source_attribute)} -> \
           #{inspect(reverse_rel.destination_attribute)}, but #{inspect(module)} has no \
           matching `borrows` relationship on that attribute pair.
           """
         )}
    end
  end

  defp verify_has_reverse(module, destination, borrows_rels, reverse_rels) do
    borrows_rels
    |> Enum.find(fn borrows_rel ->
      not Enum.any?(reverse_rels, &matching_pair?(&1, borrows_rel))
    end)
    |> case do
      nil ->
        :ok

      borrows_rel ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:relationships, borrows_rel.name],
           message: """
           #{inspect(destination)} is borrowable, but declares no `borrowed_by` matching \
           `borrows :#{borrows_rel.name}`.

           The destroy guard on #{inspect(destination)} must be able to enumerate every \
           borrower. Add to #{inspect(destination)}:

             borrowed_by :#{suggest_name(module)}, #{inspect(module)}
           """
         )}
    end
  end

  defp verify_plain_has_many(module, destination, borrows_rels, destination_rels) do
    destination_rels
    |> Enum.find(fn
      %HasMany{} = rel ->
        not AshBorrow.Info.borrowed_by?(rel) and rel.destination == module and
          Enum.any?(borrows_rels, &matching_pair?(rel, &1))

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
           #{inspect(destination)} declares `has_many :#{rel.name}` traversing the borrows \
           foreign key #{inspect(rel.destination_attribute)} of #{inspect(module)}.

           The reverse side of a borrows edge must be declared with `borrowed_by`:

             borrowed_by :#{rel.name}, #{inspect(module)}
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
