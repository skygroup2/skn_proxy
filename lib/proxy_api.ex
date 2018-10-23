defmodule Skn.Proxy.RestApi do
  @moduledoc """
      Export cowboy api for zabbix O&M
  """
  require Logger

  def init(req, opts) do
    handle(req, opts)
  end

  def route_and_process("/api/adsl_report", req) do
    method = :cowboy_req.method(req)
    {pip, _pport} = :cowboy_req.peer(req0)
    pips = :erlang.iolist_to_binary(:inet.ntoa(pip))
    if method == "POST" do
      # new report api
      {:ok, body, _req} = :cowboy_req.read_body(req1)
      js = Poison.decode!(body)
      ssh_ip = js["ssh_ip"]
      ssh_port = js["ssh_port"]
      ip = pips
      port = js["port"]
      case Skn.Util.check_ipv4(ip) do
        {true, :public} ->
          if pips != js["ip"] do
            Logger.error("ADSL #{ssh_ip}:#{ssh_port} wrong report #{pips} vs #{js["ip"]}")
          end
          S5Proxy.update_adsl(%{ssh_ip: ssh_ip, ssh_port: ssh_port, ip: ip, port: port})
        _ ->
          Logger.error("ADSL is not public ip address #{inspect js}")
      end
      {200, "OK"}
    else
      {501, "Not Implemented"}
    end
  end

  def route_and_process(_path, _req) do
    {404, "0"}
  end

  def handle(req, state) do
    try do
      path = :cowboy_req.path(req)
      {code, respb} = route_and_process(path, req)
      headers = %{"content-type" => "text/html; charset=utf-8"}
      req2 = :cowboy_req.reply(code, headers, respb, req)
      {:ok, req2, state}
    catch
      _, exp ->
        Logger.error "proxy exp #{inspect exp}"
        Logger.error "proxy trace #{inspect System.stacktrace()}"
        headers = %{"content-type" => "text/html; charset=utf-8"}
        req2 = :cowboy_req.reply(500, headers, "0", req)
        {:ok, req2, state}
    end
  end

  def info(_info, req, state) do
    {:ok, req, state}
  end

  def terminate(_reason, _req, _state) do
    :ok
  end

end