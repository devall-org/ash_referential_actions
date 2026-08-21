defmodule AshReferentialActions do
  @moduledoc """
  Declares referential actions for Ash relationships.

  Persistent relationships must state what happens when the referenced record
  is destroyed:

  * `cascade_*` destroys related records through their primary destroy action.
  * `restrict_*` rejects the destroy while live related records exist.
  * `nilify_*` clears the foreign key on live related records.
  * `view_*` is lifecycle-neutral and exists only for loading or querying.

  The action is declared on both sides of an attributable relationship:

      relationships do
        req_cascade_belongs_to :invoice, Invoice
      end

      relationships do
        cascade_has_many :line_items, LineItem
      end

  Use `AshReferentialActions.Archival` to apply these semantics to soft
  archive, or `AshReferentialActions.Postgres` to apply them to physical
  PostgreSQL deletes.
  """

  @actions [:cascade, :restrict, :nilify, :view]
  @belongs_variants [
    {nil, nil, nil},
    {:req, false, true},
    {:req_priv, false, false},
    {:opt, true, true},
    {:opt_priv, true, false}
  ]

  @ash_relationship_entities Ash.Resource.Dsl.sections()
                             |> Enum.find(&(&1.name == :relationships))
                             |> Map.fetch!(:entities)
                             |> Map.new(&{&1.name, &1})

  @belongs_entities (for action <- @actions,
                         {variant, allow_nil?, public?} <- @belongs_variants,
                         not (action == :nilify and allow_nil? == false) do
                       name =
                         case variant do
                           nil -> :"#{action}_belongs_to"
                           variant -> :"#{variant}_#{action}_belongs_to"
                         end

                       fixed =
                         [allow_nil?: allow_nil?, public?: public?]
                         |> Enum.reject(fn {_key, value} -> is_nil(value) end)

                       base = Map.fetch!(@ash_relationship_entities, :belongs_to)

                       %{
                         base
                         | name: name,
                           describe: "Declares a #{action} belongs_to relationship.",
                           examples: ["#{name} :parent, Parent"],
                           no_depend_modules: [:destination],
                           schema: Keyword.drop(base.schema, Keyword.keys(fixed)),
                           transform: {__MODULE__, :transform_relationship, [action]},
                           auto_set_fields: fixed
                       }
                     end)

  @has_many_entities (for action <- @actions do
                        name = :"#{action}_has_many"

                        base = Map.fetch!(@ash_relationship_entities, :has_many)

                        %{
                          base
                          | name: name,
                            describe: "Declares a #{action} has_many relationship.",
                            examples: ["#{name} :children, Child"],
                            no_depend_modules: [:destination],
                            transform: {__MODULE__, :transform_relationship, [action]}
                        }
                      end)

  @has_one_entities (for action <- @actions do
                       name = :"#{action}_has_one"

                       base = Map.fetch!(@ash_relationship_entities, :has_one)

                       %{
                         base
                         | name: name,
                           describe: "Declares a #{action} has_one relationship.",
                           examples: ["#{name} :child, Child"],
                           no_depend_modules: [:destination],
                           transform: {__MODULE__, :transform_relationship, [action]}
                       }
                     end)

  use Spark.Dsl.Extension,
    dsl_patches:
      Enum.map(
        @belongs_entities ++ @has_many_entities ++ @has_one_entities,
        &%Spark.Dsl.Patch.AddEntity{section_path: [:relationships], entity: &1}
      ),
    verifiers: [
      AshReferentialActions.Verifiers.NoPlainRelationships,
      AshReferentialActions.Verifiers.PairConsistency
    ]

  @doc false
  def transform_relationship(relationship, action) do
    module = relationship.__struct__

    with {:ok, relationship} <- module.transform(relationship) do
      {:ok, Map.put(relationship, :__referential_action__, action)}
    end
  end
end
