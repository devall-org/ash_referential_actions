defmodule AshBorrow.Test.Support.GuardResources do
  @moduledoc false

  alias AshBorrow.Test.Support.GuardResources

  defmodule Snapshot do
    @moduledoc false
    use Ash.Resource,
      domain: GuardResources.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBorrow, AshArchival.Resource]

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      used_by :docs, GuardResources.Doc
    end
  end

  defmodule Doc do
    @moduledoc false
    use Ash.Resource,
      domain: GuardResources.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBorrow, AshArchival.Resource]

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]

      update :atomic_retarget do
        require_atomic? true
        argument :new_snapshot_id, :uuid, allow_nil?: false
        change atomic_update(:snapshot_id, expr(^arg(:new_snapshot_id)))
      end
    end

    relationships do
      uses :snapshot, GuardResources.Snapshot do
        attribute_writable? true
        attribute_public? true
      end
    end
  end

  defmodule FlagAwarePrep do
    @moduledoc false
    # Global preparation following the documented contract: hide inactive
    # rows from default reads, but pass guard queries through.
    use Ash.Resource.Preparation

    @impl true
    def prepare(query, _opts, _context) do
      if query.context[:ash_borrow_guard?] do
        query
      else
        Ash.Query.do_filter(query, active: true)
      end
    end
  end

  defmodule PrepSnapshot do
    @moduledoc false
    # Borrowable hidden from default reads by a flag-aware global preparation:
    # the target-live guard must still see it.
    use Ash.Resource,
      domain: GuardResources.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBorrow, AshArchival.Resource]

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :active, :boolean, public?: true, allow_nil?: false, default: false
    end

    preparations do
      prepare GuardResources.FlagAwarePrep
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      used_by :prep_docs, GuardResources.PrepDoc
    end
  end

  defmodule PrepDoc do
    @moduledoc false
    # Borrower hidden from default reads by a flag-aware global preparation:
    # the guard must still see it.
    use Ash.Resource,
      domain: GuardResources.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBorrow, AshArchival.Resource]

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :active, :boolean, public?: true, allow_nil?: false, default: false
    end

    preparations do
      prepare GuardResources.FlagAwarePrep
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      uses :prep_snapshot, GuardResources.PrepSnapshot do
        attribute_writable? true
        attribute_public? true
      end
    end
  end

  defmodule NaSnapshot do
    @moduledoc false
    # Non-archival borrowable: destroys are hard deletes; the guard must
    # still reject them while borrowers exist (no FK on ETS).
    use Ash.Resource,
      domain: GuardResources.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBorrow]

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      used_by :na_docs, GuardResources.NaDoc
    end

    # Optional override for the guard's rejection message.
    def used_message(:na_docs), do: "NaSnapshot is still in use"
    def used_message(_other), do: nil
  end

  defmodule NaDoc do
    @moduledoc false
    use Ash.Resource,
      domain: GuardResources.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBorrow]

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      uses :na_snapshot, GuardResources.NaSnapshot do
        attribute_writable? true
        attribute_public? true
      end
    end
  end

  defmodule FilteredSnapshot do
    @moduledoc false
    use Ash.Resource,
      domain: GuardResources.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBorrow, AshArchival.Resource]

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end

    relationships do
      # FilteredDoc's primary read is filtered, so the destroy guard must be
      # pointed at an explicit unfiltered read action.
      used_by :filtered_docs, GuardResources.FilteredDoc do
        read_action :guard_read
      end
    end
  end

  defmodule FilteredDoc do
    @moduledoc false
    # Borrower whose primary read hides inactive rows: the guard must still
    # count them as live borrowers, via the declared :guard_read action.
    use Ash.Resource,
      domain: GuardResources.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBorrow, AshArchival.Resource]

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :active, :boolean, public?: true, allow_nil?: false, default: false
    end

    actions do
      defaults [:destroy, create: :*]

      read :read do
        primary? true
        filter expr(active == true)
      end

      read :guard_read
    end

    relationships do
      uses :filtered_snapshot, GuardResources.FilteredSnapshot do
        attribute_writable? true
        attribute_public? true
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource GuardResources.Snapshot
      resource GuardResources.Doc
      resource GuardResources.NaSnapshot
      resource GuardResources.NaDoc
      resource GuardResources.FilteredSnapshot
      resource GuardResources.FilteredDoc
      resource GuardResources.PrepSnapshot
      resource GuardResources.PrepDoc
    end
  end
end
