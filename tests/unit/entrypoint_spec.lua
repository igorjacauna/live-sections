local stub = require("stubs.reaper")

local ENTRYPOINT = "LiveSections/LiveSections.lua"

local function fake_imgui()
  local calls = {}
  local ImGui = {}
  function ImGui.CreateContext(name) calls[#calls + 1] = "CreateContext"; return { name = name } end
  function ImGui.Begin() calls[#calls + 1] = "Begin"; return true, true end
  function ImGui.Text() calls[#calls + 1] = "Text" end
  function ImGui.End() calls[#calls + 1] = "End" end
  return ImGui, calls
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

    local deferred = r.calls_to("defer")
    assert.equal(1, #deferred)
    deferred[1][1]()
    assert.same({ "CreateContext", "Begin", "Text", "End" }, calls)
    assert.equal(2, #r.calls_to("defer"))
  end)
end)
