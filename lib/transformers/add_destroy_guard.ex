defmodule AshOwnership.Transformers.AddDestroyGuard do
  @moduledoc false
  # Prepends AshOwnership.Changes.EnsureNotLocked to every destroy action of a
  # resource with the AshOwnership extension, so a used record can neither be hard-deleted nor
  # archived (archival rewrites destroys into soft updates, keeping the
  # change) while live users exist.
  #
  # Prepending puts the guard's `before_action` hook in first, and Ash runs
  # before_action hooks last-registered-first, so the guard ends up running
  # after the resource's own checks. That matters because Ash stops at the
  # first error: an application's domain message wins over this library's
  # generic wording when both would reject the same destroy.
  #
  # Ordering mirrors AshArchival's SetupArchival and additionally runs before
  # it, so the guard is in place before archival rewrites the destroy actions.
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # `defaults [:destroy]` is expanded into a real destroy action by
  # SetPrimaryActions, so the guard must be added after it; SetupArchival then
  # rewrites the destroys into soft updates while keeping existing changes.
  @impl true
  def after?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def after?(_), do: false

  @impl true
  def before?(AshArchival.Resource.Transformers.SetupArchival), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    # Nothing to enumerate without locked_by edges. A resource that is
    # actually used always has them (the using-side verifier requires
    # a matching one), so skipping here only spares resources nobody locks.
    if Enum.any?(Ash.Resource.Info.relationships(dsl_state), &AshOwnership.Info.locked_by?/1) do
      add_guard(dsl_state)
    else
      {:ok, dsl_state}
    end
  end

  defp add_guard(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type == :destroy))
    |> Enum.reduce({:ok, dsl_state}, fn destroy_action, {:ok, dsl_state} ->
      with {:ok, guard} <-
             Transformer.build_entity(Ash.Resource.Dsl, [:actions, :destroy], :change,
               change: {AshOwnership.Changes.EnsureNotLocked, []}
             ) do
        new_action = %{destroy_action | changes: [guard | destroy_action.changes]}

        {:ok,
         Transformer.replace_entity(
           dsl_state,
           [:actions],
           new_action,
           &(&1.name == destroy_action.name)
         )}
      end
    end)
  end
end
