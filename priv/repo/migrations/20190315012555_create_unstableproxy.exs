defmodule Skn.EA.Repo.Migrations.FreeProxy do
  use Ecto.Migration

  def up do
    IO.puts("Creating table skn_unstableproxy")
    create_if_not_exists table(:skn_unstableproxy) do
      add :address,   :string,  size: 50
      add :port,      :integer, default: 0
      add :real_ip,   :string,  size: 50
      add :protocol,  :string,  default: "http", size: 20
      add :connect,   :integer, default: 1
      add :zone,      :string,  default: "unstable", size: 20
      add :country,   :string,  default: "", size: 2
      add :status,    :integer, default: 0
      add :info,      :map,     default: %{}
      timestamps()
    end
    create index("skn_unstableproxy", [:address, :port], unique: true)
  end

  def down do
    IO.puts("Dropping table skn_unstableproxy")
    drop_if_exists table(:skn_unstableproxy)
    drop index("skn_unstableproxy", [:address, :port])
  end
end
