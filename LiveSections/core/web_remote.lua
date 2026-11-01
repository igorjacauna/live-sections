-- Endereço da página do celular/tablet: a porta da Web Interface do REAPER
-- (linha "HTTP" das superfícies de controle no reaper.ini) e os IPs desta
-- máquina na rede local. Assim a tela de configurações mostra o endereço
-- pronto para digitar no celular.
--
-- M.parse_ini(text) -> { { port, page } }   uma por Web Interface
-- M.parse_ips(text) -> { ip }               saída do ifconfig/ip/ipconfig
-- M.info(force) -> { ports, ips, urls, page_installed }   em cache

local M = {}

M.PAGE = "livesections.html"

local cache = nil

function M.parse_ini(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local rest = line:match("^csurf_%d+=HTTP%s+(.*)$")
    if rest then
      local port = tonumber(rest:match("^%-?%d+%s+(%d+)") or "")
      local page
      for q in rest:gmatch("'([^']*)'") do
        if q:lower():match("%.html?$") then page = q end
      end
      if port and port > 0 and port < 65536 then out[#out + 1] = { port = port, page = page } end
    end
  end
  return out
end

-- Só endereços de rede local (192.168.x, 10.x, 172.16–31.x).
local function private(ip)
  local a, b = ip:match("^(%d+)%.(%d+)%.")
  a, b = tonumber(a), tonumber(b)
  return a == 192 and b == 168 or a == 10 or a == 172 and b >= 16 and b <= 31
end

-- Adaptadores virtuais (WSL, Hyper-V, VirtualBox, VMware, Docker, VPN)
-- também têm IP "de rede local", mas o celular não chega neles.
local VIRTUAL = { "vethernet", "hyper%-v", "wsl", "virtualbox", "vmware", "vmnet", "docker", "utun", "loopback" }

local function virtual(adapter)
  adapter = adapter:lower()
  for _, p in ipairs(VIRTUAL) do if adapter:find(p) then return true end end
  return false
end

function M.parse_ips(text)
  local out, seen = {}, {}
  local adapter = ""
  for line in (text or ""):gmatch("[^\r\n]+") do
    -- cabeçalho do adaptador: linha sem recuo ("Adaptador Ethernet vEthernet (WSL):", "en0: flags=…")
    if line:match("^%S") then adapter = line end
    -- Windows: "Endereço IPv4. . . : 192.168.0.23" (às vezes com "(Preferencial)")
    local ip = line:find("IPv4", 1, true) and line:match("IPv4.-:%s*(%d+%.%d+%.%d+%.%d+)")
      or line:match("inet%s+(%d+%.%d+%.%d+%.%d+)") or line:match("inet addr:(%d+%.%d+%.%d+%.%d+)")
    if ip and private(ip) and not seen[ip] and not virtual(adapter) then
      seen[ip] = true
      out[#out + 1] = ip
    end
  end
  return out
end

local function read(path)
  local f = path and io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function ifconfig()
  local os_name = reaper.GetOS():lower()
  local cmd = os_name:match("^win") and "ipconfig"
    or (os_name:match("^osx") or os_name:match("^macos")) and "/sbin/ifconfig"
    or "/sbin/ip -4 addr"
  local out = reaper.ExecProcess(cmd, 2000) or ""
  return (out:gsub("^[^\n]*\n", ""))     -- 1ª linha: código de saída
end

function M.info(force)
  if cache and not force then return cache end
  local ports = M.parse_ini(read(reaper.get_ini_file()))
  local ips = M.parse_ips(ifconfig())
  local urls = {}
  for _, p in ipairs(ports) do
    for _, ip in ipairs(ips) do
      urls[#urls + 1] = string.format("http://%s:%d/%s", ip, p.port, M.PAGE)
    end
  end
  local page = io.open(reaper.GetResourcePath() .. "/reaper_www_root/" .. M.PAGE, "r")
  if page then page:close() end
  cache = { ports = ports, ips = ips, urls = urls, page_installed = page ~= nil }
  return cache
end

return M
