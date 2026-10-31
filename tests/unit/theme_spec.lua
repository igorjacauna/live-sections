-- ImGui falsa: registra as chamadas, com constantes só para parte das cores.
local function fake_imgui()
  local calls = {}
  local im = setmetatable({ calls = calls, Col_Text = 0, Col_WindowBg = 2, Col_Button = 21, StyleVar_FrameRounding = 12, StyleVar_WindowPadding = 2 }, {
    __index = function(_, name)
      if name:match("^Col_") or name:match("^StyleVar_") then return nil end
      return function(...) calls[#calls + 1] = { name, ... }; if name == "CreateFont" then return { file = select(1, ...), size = select(2, ...) } end end
    end,
  })
  return im
end

describe("ui.theme", function()
  local theme, im
  local ROOT = "LiveSections/"

  local function count(name)
    local n = 0
    for _, c in ipairs(im.calls) do if c[1] == name then n = n + 1 end end
    return n
  end

  before_each(function()
    package.loaded["ui.theme"] = nil
    theme = require("ui.theme")
    im = fake_imgui()
  end)

  it("converte cores do protótipo para 0xRRGGBBAA", function()
    assert.equal(0x0A0D12FF, theme.C.bg)
    assert.equal(0xFFB54780, theme.rgba("#FFB547", 0.5))
    assert.equal(0x808080FF, theme.mix(0x000000FF, 0xFFFFFFFF, 0.5) | 0xFF)
  end)

  it("carrega as fontes do pacote, uma por arquivo e tamanho, antes do primeiro frame", function()
    assert.is_true(theme.init("ctx", im, ROOT))
    local created = count("CreateFont")
    assert.equal(created, count("Attach"))
    local styles = 0
    for _ in pairs(theme.TEXT) do styles = styles + 1 end
    assert.is_true(created <= styles)
    assert.is_true(theme.font("ctx", "h1"))
    theme.pop_font("ctx", true)
    assert.equal(1, count("PushFont"))
  end)

  it("sem os arquivos, avisa e o texto usa a fonte padrão", function()
    local ok, err = theme.init("ctx", im, "/nao/existe/")
    assert.is_false(ok)
    assert.matches("^font_missing", err)
    assert.is_false(theme.font("ctx", "body"))
    theme.pop_font("ctx", false)
    assert.equal(0, count("PopFont"))
  end)

  it("push aplica as cores e estilos que a versão tem e pop desfaz o mesmo número", function()
    theme.init("ctx", im, ROOT)
    theme.push("ctx")
    assert.equal(3, count("PushStyleColor"))
    assert.equal(2, count("PushStyleVar"))
    theme.pop("ctx")
    local pops = {}
    for _, c in ipairs(im.calls) do if c[1]:match("^Pop") then pops[c[1]] = c[3] end end
    assert.same({ PopStyleColor = 3, PopStyleVar = 2 }, pops)
  end)

  it("cada estado tem ícone e texto além da cor (RF-078)", function()
    theme.init("ctx", im, ROOT)
    for _, state in ipairs({ "playing", "queued", "loop", "error" }) do
      local s = theme.STATE[state]
      assert.is_string(s.label)
      assert.is_true(s.label ~= "")
      assert.has_no.errors(function() theme.icon("dl", s.icon, 0, 0, 16, s.color) end)
    end
  end)

  it("todos os ícones desenham; nome desconhecido é erro", function()
    theme.init("ctx", im, ROOT)
    for _, name in ipairs(theme.ICON_NAMES) do theme.icon("dl", name, 10, 10, 24, theme.C.text) end
    assert.has_error(function() theme.icon("dl", "nada", 0, 0, 16, 0) end)
  end)
end)
