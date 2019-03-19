defmodule Skn.Proxy.Repo do
  use Ecto.Repo,
    otp_app: :skn_proxy,
    adapter: Ecto.Adapters.Postgres
  require Record

  @proxy_status_fields [id: :nil, ip: "", tag: :static, assign: :farmer, info: %{}]
  Record.defrecord :proxy_status, @proxy_status_fields

  @proxy_ip2_fields [id: "", keeper: 0, info: %{}]
  Record.defrecord :proxy_ip2, @proxy_ip2_fields

  @proxy_dial_fields [id: "", ssh: {}, ts_reset: 0, ts_active: 0, info: %{}]
  Record.defrecord :proxy_dial, @proxy_dial_fields

  def fields(x) do
    Keyword.keys x
  end

  def create_table() do
    :mnesia.create_table(
      :proxy_status,
      [disc_copies: [node()], record_name: :proxy_status, index: [:ip], attributes: fields(@proxy_status_fields)]
    )
    :mnesia.create_table(
      :proxy_ip2,
      [disc_copies: [node()], record_name: :proxy_ip2, index: [:keeper], attributes: fields(@proxy_ip2_fields)]
    )
    :mnesia.create_table(
      :proxy_dial,
      [disc_copies: [node()], record_name: :proxy_dial, index: [:ssh], attributes: fields(@proxy_dial_fields)]
    )
  end

  def create_db() do
    :ets.new(:proxy_country_percent, [:public, :set, :named_table, {:read_concurrency, true}])
  end

  def init(_, opts) do
    {:ok, Keyword.put(opts, :url, System.get_env("DATABASE_URL"))}
  end
end

defmodule Skn.Proxy.Repo.GeoIP do
  use Ecto.Schema
  import Ecto.Changeset
  alias Skn.Proxy.Repo.GeoIP

  @primary_key {:address, :string, []}
  schema "hog_geoip" do
    field :country, :string
    field :geo, :map

    timestamps([type: :utc_datetime_usec])
  end

  def changeset(%GeoIP{} = card_info, attrs) do
    card_info
    |> cast(attrs, [:address, :country, :geo])
    |> validate_required([:address])
  end
end

defmodule Skn.Proxy.Repo.FreeProxy do
  use Ecto.Schema
  import Ecto.Changeset
  alias Skn.Proxy.Repo.FreeProxy

  schema "hog_unstableproxy" do
    field :address, :string
    field :port, :integer
    field :real_ip, :string
    field :protocol, :string
    field :connect, :integer
    field :zone, :string
    field :country, :string
    field :status, :integer
    field :info, :map

    timestamps([type: :utc_datetime_usec])
  end

  def changeset(%FreeProxy{} = card_info, attrs) do
    card_info
    |> cast(attrs, [:address, :port, :real_ip, :protocol, :connect, :zone, :country, :status, :info])
    |> validate_required([:address, :port])
  end
end

defmodule Skn.Proxy.SqlApi do
  import Ecto.Query
  alias Skn.Proxy.Repo
  alias Skn.Proxy.Repo.GeoIP
  alias Skn.Proxy.Repo.FreeProxy

  def proxy_status_idle, do: 0
  def proxy_status_alive, do: 1
  def proxy_status_geo, do: 2
  def proxy_status_dead, do: 3
  def proxy_status_no_protocol, do: 4
  def proxy_status_no_geo, do: 5

  def format_map_from_struct(attrs) do
    if Map.has_key?(attrs, :__struct__) do
      Map.drop Map.from_struct(attrs), [:updated_at, :inserted_at, :__meta__]
    else
      attrs
    end
  end

  def update_proxy(attrs) do
    attrs = format_map_from_struct(attrs)
    address = Map.get(attrs, :address, nil)
    port = Map.get(attrs, :port, nil)
    can_insert = attrs[:real_ip] != "" and attrs[:real_ip] != nil and attrs[:protocol] != nil
    if address != nil and port != nil do
      query = from(o in FreeProxy, where: o.port == ^port and o.address == ^address)
      case Repo.one(query) do
        nil when can_insert == true ->
          %FreeProxy{}
          |> FreeProxy.changeset(attrs)
          |> Repo.insert()
          Repo.one(query)
        nil ->
          nil
        proxy ->
          proxy
          |> FreeProxy.changeset(attrs)
          |> Repo.update()
          Repo.one(query)
      end
    else
      nil
    end
  end

  def list_proxy_by_zone_status(zone, status, cmp \\ :==, limit \\ 100) do
    query = case cmp do
      _ ->
        from(o in FreeProxy, where: o.status == ^status and o.zone == ^zone, limit: ^limit, select: o)
    end
    Repo.all(query)
  end

  def list_proxy_by_status(status, cmp \\ :==, limit \\ 100) do
    query = case cmp do
      _ ->
        from(o in FreeProxy, where: o.status == ^status, limit: ^limit, select: o)
    end
    Repo.all(query)
  end

  def update_GeoIP(attrs) do
    attrs = format_map_from_struct(attrs)
    ip = Map.get(attrs, :address, nil)
    country = Map.get(attrs, :country, nil)
    case get_GeoIP(ip) do
      r when is_map(r) ->
        r
        |> GeoIP.changeset(attrs)
        |> Repo.update()
      _ when ip != nil and country != nil ->
        %GeoIP{}
        |> GeoIP.changeset(attrs)
        |> Repo.insert()
      _ ->
        :ignore
    end
  end

  def get_GeoIP(address) do
    Repo.get(GeoIP, address)
  end
end