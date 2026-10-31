local stub = require("stubs.reaper")

local ENTRYPOINT = "LiveSections/LiveSections.lua"

-- ImGui falsa: registra as chamadas; funções sem retorno especial devolvem
-- 0, 0 (posições) e constantes de estilo não existem.
local function fake_imgui()
  local calls = {}
  local ImGui = setmetatable({}, {
    __index = function(_, name)
      if name:match("^Col_") or name:match("^StyleVar_") then return nil end
      return function() calls[#calls + 1] = name; return 0, 0 end
    end,
  })
  function ImGui.CreateContext(name) calls[#calls + 1] = "CreateContext"; return { name = name } end
  function ImGui.Begin() calls[#calls + 1] = "Begin"; return true, true end
  return ImGui, calls
end

local function only(calls, names)
  local out = {}
  for _, c in ipairs(calls) do if names[c] then out[#out + 1] = c end end
  return out
end

describe("entrypoint", function()
  local r, saved_path

  before_each(function()
    r = stub.install()
    saved_path = package.path
    package.loaded.imgui = nil
    package.preload.imgui = nil
  end)

  after_each(function()
    package.path = saved_path
    package.loaded.imgui = nil
    package.preload.imgui = nil
  end)

  it("sem ReaImGui, mostra como instalar pelo ReaPack e não abre a janela", function()
    dofile(ENTRYPOINT)

    local mb = r.calls_to("MB")
    assert.equal(1, #mb)
    assert.matches("ReaImGui", mb[1][1])
    assert.matches("ReaPack", mb[1][1])
    assert.equal(0, #r.calls_to("defer"))
  end)

  it("com REAPER anterior ao 7, avisa a versão mínima", function()
    r.set_app_version("6.83/macOS-arm64")
    r.install_imgui("/imgui")

    dofile(ENTRYPOINT)

    local mb = r.calls_to("MB")
    assert.equal(1, #mb)
    assert.matches("REAPER 7%.0", mb[1][1])
    assert.matches("6%.83", mb[1][1])
    assert.equal(0, #r.calls_to("defer"))
  end)

  it("com dependências ok, ajusta package.path e roda o loop da janela", function()
    r.install_imgui("/imgui")
    local ImGui, calls = fake_imgui()
    local requested_version
    package.preload.imgui = function()
      return function(version) requested_version = version; return ImGui end
    end

    dofile(ENTRYPOINT)

    assert.equal(0, #r.calls_to("MB"))
    assert.equal("0.9", requested_version)
    assert.matches("^/stub/LiveSections/%?%.lua;/imgui/%?%.lua;", package.path)

    local clears_leds = false
    for _, c in ipairs(r.calls_to("atexit")) do
      if c[1] == package.loaded["midi.feedback"].clear then clears_leds = true end
    end
    assert.is_true(clears_leds)
    local deferred = r.calls_to("defer")
    assert.equal(1, #deferred)
    deferred[1][1]()
    assert.same({ "CreateContext", "Begin", "End" }, only(calls, { CreateContext = true, Begin = true, End = true }))
    assert.equal(2, #r.calls_to("defer"))
  end)
end)
