defmodule AshReferentialActions.Verifiers.PairConsistency do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Ash.Resource.Relationships.BelongsTo
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(match?(%BelongsTo{}, &1) and lifecycle?(&1)))
    |> Enum.reduce_while(:ok, fn forward, :ok ->
      case verify_forward(module, forward) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp lifecycle?(rel),
    do: AshReferentialActions.Info.action(rel) in [:cascade, :restrict, :nilify]

  defp verify_forward(module, forward) do
    action = AshReferentialActions.Info.action(forward)
    destination = forward.destination

    cond do
      not AshReferentialActions.Info.enabled?(destination) ->
        error(module, forward, "#{inspect(destination)} must use AshReferentialActions")

      true ->
        verify_reverse(module, forward, action)
    end
  end

  defp verify_reverse(module, forward, action) do
    matching =
      forward.destination
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(fn reverse ->
        reverse.destination == module and
          AshReferentialActions.Info.reverse_of?(reverse, forward)
      end)

    case Enum.find(matching, &(AshReferentialActions.Info.action(&1) == action)) do
      nil ->
        declared = Enum.map(matching, &AshReferentialActions.Info.action/1)

        error(
          module,
          forward,
          "#{inspect(forward.destination)} must declare a matching #{action}_has_many/has_one; " <>
            "matching actions found: #{inspect(declared)}"
        )

      _reverse ->
        :ok
    end
  end

  defp error(module, rel, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: module,
       path: [:relationships, rel.name],
       message: message
     )}
  end
end
