defmodule AshOwnership.MarkerSurvivalTest do
  use ExUnit.Case, async: true

  alias AshOwnership.Test.Support.TestResources

  test "uses compiles to a BelongsTo that keeps the :__uses__ marker" do
    rel = Ash.Resource.Info.relationship(TestResources.Doc, :snapshot)

    assert %Ash.Resource.Relationships.BelongsTo{} = rel
    assert Map.get(rel, :__uses__) == true
    assert rel.destination == TestResources.Snapshot
  end

  test "uses passes belongs_to options through" do
    defmodule RequiredSnapshot do
      @moduledoc false
      use Ash.Resource, domain: nil, extensions: [AshOwnership]

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end

      relationships do
        used_by :required_borrow_docs, AshOwnership.MarkerSurvivalTest.RequiredBorrowDoc do
          destination_attribute :snapshot_id
        end
      end
    end

    defmodule RequiredBorrowDoc do
      @moduledoc false
      use Ash.Resource, domain: nil, extensions: [AshOwnership]

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end

      relationships do
        uses :snapshot, AshOwnership.MarkerSurvivalTest.RequiredSnapshot do
          allow_nil? false
          public? true
        end
      end
    end

    rel = Ash.Resource.Info.relationship(RequiredBorrowDoc, :snapshot)

    assert Map.get(rel, :__uses__) == true
    assert rel.allow_nil? == false
    assert rel.public? == true
  end

  test "req/opt and pub/priv variants set allow_nil? and public?" do
    defmodule VariantSnapshot do
      @moduledoc false
      use Ash.Resource, domain: nil, extensions: [AshOwnership]

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end

      relationships do
        for name <- [:req_docs, :req_priv_docs, :opt_docs, :opt_priv_docs] do
          used_by name, AshOwnership.MarkerSurvivalTest.VariantDoc do
            destination_attribute :"#{name}_snapshot_id"
          end
        end
      end
    end

    defmodule VariantDoc do
      @moduledoc false
      use Ash.Resource, domain: nil, extensions: [AshOwnership]

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end

      relationships do
        req_uses :req_docs_snapshot, AshOwnership.MarkerSurvivalTest.VariantSnapshot
        req_priv_uses :req_priv_docs_snapshot, AshOwnership.MarkerSurvivalTest.VariantSnapshot
        opt_uses :opt_docs_snapshot, AshOwnership.MarkerSurvivalTest.VariantSnapshot
        opt_priv_uses :opt_priv_docs_snapshot, AshOwnership.MarkerSurvivalTest.VariantSnapshot
      end
    end

    expected = %{
      req_docs_snapshot: {false, true},
      req_priv_docs_snapshot: {false, false},
      opt_docs_snapshot: {true, true},
      opt_priv_docs_snapshot: {true, false}
    }

    for {name, {allow_nil?, public?}} <- expected do
      rel = Ash.Resource.Info.relationship(VariantDoc, name)

      assert AshOwnership.Info.uses?(rel)
      assert rel.allow_nil? == allow_nil?, "#{name} allow_nil?"
      assert rel.public? == public?, "#{name} public?"
      # public? drives attribute_public? unless set explicitly
      assert rel.attribute_public? == public?, "#{name} attribute_public?"
    end
  end

  test "used_by compiles to a HasMany that keeps the :__used_by__ marker" do
    rel = Ash.Resource.Info.relationship(TestResources.Snapshot, :docs)

    assert %Ash.Resource.Relationships.HasMany{} = rel
    assert Map.get(rel, :__used_by__) == true
    assert rel.destination == TestResources.Doc
    assert rel.destination_attribute == :snapshot_id
  end

  test "plain belongs_to and has_many carry no markers" do
    defmodule PlainParent do
      @moduledoc false
      use Ash.Resource, domain: nil

      attributes do
        uuid_primary_key(:id)
      end

      relationships do
        has_many(:children, AshOwnership.MarkerSurvivalTest.PlainChild)
      end
    end

    defmodule PlainChild do
      @moduledoc false
      use Ash.Resource, domain: nil

      attributes do
        uuid_primary_key(:id)
      end

      relationships do
        belongs_to(:plain_parent, AshOwnership.MarkerSurvivalTest.PlainParent)
      end
    end

    refute Ash.Resource.Info.relationship(PlainChild, :plain_parent) |> Map.get(:__uses__)
    refute Ash.Resource.Info.relationship(PlainParent, :children) |> Map.get(:__used_by__)
  end

  test "ancestor compiles to a BelongsTo that keeps the :__ancestor__ marker" do
    defmodule Org do
      @moduledoc false
      use Ash.Resource, domain: nil, extensions: [AshOwnership]

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end
    end

    # Org declares no reverse relationship: an ancestor needs none, because the
    # record's real parent is elsewhere.
    defmodule Row do
      @moduledoc false
      use Ash.Resource, domain: nil, extensions: [AshOwnership]

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end

      relationships do
        ancestor(:org, AshOwnership.MarkerSurvivalTest.Org)
      end
    end

    rel = Ash.Resource.Info.relationship(Row, :org)

    assert %Ash.Resource.Relationships.BelongsTo{} = rel
    assert Map.get(rel, :__ancestor__) == true
    assert Map.get(rel, :__uses__) != true
    assert rel.destination == AshOwnership.MarkerSurvivalTest.Org
    assert AshOwnership.Info.ancestor?(rel)
  end
end
