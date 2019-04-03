defmodule Skn.EA.Repo.Migrations.CreateGeoIP do
  use Ecto.Migration

  def up do
    IO.puts("Creating table skn_geoip")
    create_if_not_exists table(:skn_geoip, primary_key: false) do
      add :address,   :string,  primary_key: true, size: 50
      add :country,   :string,  default: "", size: 2
      add :geo,       :map,     default: %{}
      timestamps()
    end
  end

  def down do
    IO.puts("Dropping table skn_geoip")
    drop_if_exists table(:skn_geoip)
  end
end
