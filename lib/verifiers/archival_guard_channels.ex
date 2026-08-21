defmodule AshReferentialActions.Verifiers.ArchivalGuardChannels do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Ash.Resource.Relationships.BelongsTo
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(match?(%BelongsTo{}, &1) and AshReferentialActions.Info.guarded?(&1)))
    |> Enum.find_value(fn forward -> channel_error(module, forward) end)
    |> case do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp channel_error(module, forward) do
    reverses =
      forward.destination
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(fn reverse ->
        reverse.destination == module and
          AshReferentialActions.Info.action(reverse) ==
            AshReferentialActions.Info.action(forward) and
          AshReferentialActions.Info.reverse_of?(reverse, forward)
      end)

    cond do
      unclean?(forward) ->
        error(module, forward, "forward guard read action is filtered or uncallable")

      reverses == [] ->
        nil

      Enum.all?(reverses, &unclean?/1) ->
        error(module, forward, "every reverse guard read action is filtered or uncallable")

      true ->
        nil
    end
  end

  defp unclean?(rel) do
    case AshReferentialActions.Query.guard_read_action(rel) do
      nil ->
        true

      name ->
        case Ash.Resource.Info.action(rel.destination, name) do
          nil -> true
          action -> AshReferentialActions.Query.unclean_read_action?(action)
        end
    end
  end

  defp error(module, rel, message) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:relationships, rel.name],
      message: message
    )
  end
end
