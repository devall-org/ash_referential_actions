defmodule AshOwnership.Query do
  @moduledoc false
  # Shared query plumbing for the runtime guards.

  @doc false
  # The read action a guard locks to query through `rel`: the relationship's
  # `read_action` if set, otherwise the destination's primary read.
  # `AshOwnership.Verifiers.LockedByConsistency` guarantees at compile time
  # that whichever action this resolves to carries no action-level
  # filters/preparations, so it cannot hide physically live rows.
  def guard_read_action(rel) do
    rel.read_action ||
      case Ash.Resource.Info.primary_action(rel.destination, :read) do
        nil -> nil
        action -> action.name
      end
  end

  @doc false
  # Returns true when a read action is unsuitable as a guard default:
  # action-level filters/preparations can hide physically live rows, and a
  # required argument without a default makes the query uncallable.
  def unclean_read_action?(action) do
    action.filter != nil or action.filters != [] or action.preparations != [] or
      Enum.any?(action.arguments, &(not &1.allow_nil? and is_nil(&1.default)))
  end

  @doc false
  # Existence check through `rel` (a `locks` or `locked_by` relationship),
  # filtered by `filter` (keyword statement).
  #
  # `authorize?: false` bypasses policies (a policy must not be able to hide
  # rows from the guards); the changeset's tenant is forwarded so multitenant
  # resources query the right partition. Global preparations still apply —
  # notably archival's `is_nil(archived_at)` filter, which is exactly what
  # makes archived rows count as gone.
  #
  # Guard queries carry `context[:ash_ownership_guard?]`, set BEFORE for_read so
  # that global preparations see it — custom global preparations that hide
  # rows from default reads should pass the query through unchanged when this
  # flag is set.
  def exists?(rel, filter, changeset), do: exists?(rel, filter, changeset, nil)

  @doc false
  # `lock` serializes the guard against the concurrent write it is trying to
  # exclude, in whatever form the data layer names it (ash_postgres takes
  # `:for_update` as an atom and everything else as a string). Silently
  # ignored where the data layer does not support that lock (e.g. ETS), so
  # the guard stays a plain application-level check there.
  def exists?(rel, filter, changeset, lock) do
    base =
      rel.destination
      |> Ash.Query.new()
      |> Ash.Query.set_context(rel.context || %{})
      |> Ash.Query.set_context(%{ash_ownership_guard?: true})

    query =
      case guard_read_action(rel) do
        nil -> base
        action_name -> Ash.Query.for_read(base, action_name, rel.read_action_arguments || %{})
      end

    domain = rel.domain || Ash.Resource.Info.domain(rel.destination) || changeset.domain

    query
    |> Ash.Query.do_filter(filter)
    |> lock(lock)
    |> Ash.exists?(
      domain: domain,
      authorize?: false,
      tenant: changeset.tenant
    )
  end

  @doc false
  # Takes a `FOR UPDATE` lock on the record the changeset is acting on, so a
  # concurrent write that checks this record (a user being created) must
  # wait for this transaction to finish. No-op where the data layer has no
  # lock support. The record may already be filtered out (e.g. archived), in
  # which case there is nothing to serialize against.
  def lock_record(changeset) do
    resource = changeset.resource

    if Ash.DataLayer.data_layer_can?(resource, {:lock, :for_update}) do
      pkey = Ash.Resource.Info.primary_key(resource)
      filter = Enum.map(pkey, &{&1, Map.fetch!(changeset.data, &1)})

      resource
      |> Ash.Query.new()
      |> Ash.Query.set_context(%{ash_ownership_guard?: true})
      |> Ash.Query.do_filter(filter)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(
        domain: changeset.domain,
        authorize?: false,
        tenant: changeset.tenant
      )
    end

    :ok
  end

  defp lock(query, nil), do: query

  defp lock(query, lock_type) do
    if Ash.DataLayer.data_layer_can?(query.resource, {:lock, lock_type}) do
      Ash.Query.lock(query, lock_type)
    else
      query
    end
  end

  @doc false
  # Reads an attribute from the changeset's data, reloading it when it was
  # excluded by a partial select — an unloaded key must not silently make a
  # guard query match nothing.
  def data_attribute!(changeset, attribute) do
    case Map.get(changeset.data, attribute) do
      %Ash.NotLoaded{} ->
        changeset.data
        |> Ash.load!([attribute],
          domain: changeset.domain,
          authorize?: false,
          tenant: changeset.tenant
        )
        |> Map.get(attribute)

      value ->
        value
    end
  end
end
