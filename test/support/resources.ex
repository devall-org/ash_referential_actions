defmodule AshReferentialActions.Test.Resources do
  @moduledoc false

  alias AshReferentialActions.Test.Resources

  defmodule CascadeParent do
    use Ash.Resource,
      domain: AshReferentialActions.Test.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReferentialActions.Archival]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      cascade_has_many :children, Resources.CascadeChild, destination_attribute: :parent_id
    end
  end

  defmodule CascadeChild do
    use Ash.Resource,
      domain: AshReferentialActions.Test.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReferentialActions.Archival]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      cascade_belongs_to :parent, Resources.CascadeParent, allow_nil?: false
    end
  end

  defmodule RestrictTarget do
    use Ash.Resource,
      domain: AshReferentialActions.Test.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReferentialActions.Archival]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      restrict_has_many :lockers, Resources.RestrictLocker, destination_attribute: :target_id
    end
  end

  defmodule RestrictLocker do
    use Ash.Resource,
      domain: AshReferentialActions.Test.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReferentialActions.Archival]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end

    relationships do
      restrict_belongs_to :target, Resources.RestrictTarget, allow_nil?: false
    end
  end

  defmodule NilifyTarget do
    use Ash.Resource,
      domain: AshReferentialActions.Test.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReferentialActions.Archival]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      nilify_has_many :referrers, Resources.NilifyReferrer, destination_attribute: :target_id
    end
  end

  defmodule NilifyReferrer do
    use Ash.Resource,
      domain: AshReferentialActions.Test.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReferentialActions.Archival]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end

    relationships do
      nilify_belongs_to :target, Resources.NilifyTarget, allow_nil?: true
    end
  end
end
