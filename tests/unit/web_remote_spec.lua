local stub = require("stubs.reaper")

local IFCONFIG = [[
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
	inet6 ::1 prefixlen 128
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet6 fe80::1c%en0 prefixlen 64 secured scopeid 0xb
	inet 192.168.0.23 netmask 0xffffff00 broadcast 192.168.0.255
bridge0: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
	inet 169.254.10.2 netmask 0xffff0000
]]

local IPCONFIG = [[
Adaptador de Rede sem Fio Wi-Fi:

   Endereço IPv6 de link local . . . . . . . . : fe80::1%12
   Endereço IPv4. . . . . . . . . . . . . . . : 10.0.0.7
   Máscara de Sub-rede . . . . . . . . . . . . : 255.255.255.0
   Gateway Padrão. . . . . . . . . . . . . . . : 10.0.0.1
]]

describe("core.web_remote", function()
  local r, web, dir

  before_each(function()
    r = stub.install()
    package.loaded["core.web_remote"] = nil
    web = require("core.web_remote")
    dir = os.tmpname(); os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "/reaper_www_root'")
    r._resource_path = dir
  end)

  it("parse_ini: porta e página de cada Web Interface", function()
    local ini = "[reaper]\ncsurf_cnt=2\ncsurf_0=MCU 0 0 0 0\ncsurf_1=HTTP 0 8080 '' 'livesections.html' 0 ''\n"
    assert.same({ { port = 8080, page = "livesections.html" } }, web.parse_ini(ini))
    assert.same({}, web.parse_ini(nil))
  end)

  it("parse_ips: só IPs da rede local (macOS e Windows), sem gateway nem máscara", function()
    assert.same({ "192.168.0.23" }, web.parse_ips(IFCONFIG))
    assert.same({ "10.0.0.7" }, web.parse_ips(IPCONFIG))
  end)

  it("info: monta o endereço com IP, porta e a página; avisa se a página não está instalada", function()
    local f = io.open(dir .. "/reaper.ini", "w")
    f:write("csurf_0=HTTP 0 8080 '' 'index.html' 0 ''\n")
    f:close()
    r._exec = { ["/sbin/ifconfig"] = IFCONFIG }
    local info = web.info()
    assert.same({ "http://192.168.0.23:8080/livesections.html" }, info.urls)
    assert.is_false(info.page_installed)
    f = io.open(dir .. "/reaper_www_root/livesections.html", "w"); f:write("x"); f:close()
    assert.is_false(web.info().page_installed)      -- em cache
    assert.is_true(web.info(true).page_installed)
  end)

  it("sem Web Interface: nenhuma porta e nenhum endereço", function()
    local info = web.info()
    assert.same({}, info.ports)
    assert.same({}, info.urls)
  end)
end)
