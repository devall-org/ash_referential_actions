defmodule AshReferentialActions.Info do
  @moduledoc "Introspection helpers for AshReferentialActions."

  @actions [:cascade, :restrict, :nilify, :view]

  @doc "Returns the declared referential action, or nil for an unmarked relationship."
  def action(relationship), do: Map.get(relationship, :__referential_action__)

  for action <- @actions do
    @doc "Returns true when the relationship declares the #{action} action."
    def unquote(:"#{action}?")(relationship), do: action(relationship) == unquote(action)
  end

  @doc "Returns true for forward relationships whose target must be live."
  def guarded?(%Ash.Resource.Relationships.BelongsTo{} = relationship),
    do: action(relationship) in [:cascade, :restrict, :nilify]

  def guarded?(_relationship), do: false

  @doc "Returns true for reverse relationships that restrict target destruction."
  def restrict_reverse?(%kind{} = relationship)
      when kind in [Ash.Resource.Relationships.HasMany, Ash.Resource.Relationships.HasOne],
      do: restrict?(relationship)

  def restrict_reverse?(_relationship), do: false

  @doc "Returns true if the resource module has the extension."
  def enabled?(resource) when is_atom(resource) do
    AshReferentialActions in (Spark.Dsl.Extension.get_persisted(resource, :extensions) || [])
  end

  @doc "Returns true when reverse and forward relationship key attributes line up."
  def reverse_of?(reverse, forward) do
    reverse.destination_attribute == forward.source_attribute and
      reverse.source_attribute == forward.destination_attribute
  end

  @doc false
  def nilify_action_name(source_attribute),
    do: :"__ash_referential_actions_nilify_#{source_attribute}__"
end
