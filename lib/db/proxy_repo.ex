defmodule Skn.Proxy.Repo do
  require Record

  @proxy_status_fields [id: :nil, ip: "", tag: :static, assign: :farmer, info: %{}]
  Record.defrecord :proxy_status, @proxy_status_fields

  @proxy_ip2_fields [id: "", keeper: 0, info: %{}]
  Record.defrecord :proxy_ip2, @proxy_ip2_fields

  def fields(x) do
    Keyword.keys x
  end

  def create_table() do
    :mnesia.create_table(
      :proxy_status, [disc_copies: [node()], record_name: :proxy_status, index: [:ip], attributes: fields(@proxy_status_fields)]
    )
    :mnesia.create_table(
      :proxy_ip2, [disc_copies: [node()], record_name: :proxy_ip2, index: [:keeper], attributes: fields(@proxy_ip2_fields)]
    )
  end
end