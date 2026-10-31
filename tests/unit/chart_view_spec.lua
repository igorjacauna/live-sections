local stub = require("stubs.reaper")

describe("ui.chart_view", function()
  local view, calls

  before_each(function()
    stub.install()
    for _, m in ipairs({ "ui.theme", "ui.widgets", "ui.performance_view", "ui.chart_view" }) do package.loaded[m] = nil end
    calls = {}
    local im = setmetatable({}, { __index = function(_, name)
      return function(...) calls[#calls + 1] = { name, ... }; return nil end
    end })
    function im.Begin() return true, true end
    function im.GetContentRegionAvail() return 760, 520 end
    function im.GetCursorScreenPos() return 0, 0 end
    function im.CalcTextSize(_, s) return #s * 9, 14 end
    function im.GetWindowDrawList() return "dl" end
    local theme = require("ui.theme")
    theme.init("ctx", im, "/sem/fontes/")
    local pv = require("ui.performance_view")
    pv.init({ ImGui = im, theme = theme, widgets = require("ui.widgets") })
    view = require("ui.chart_view")
    view.init({ ImGui = im, theme = theme, kit = pv.kit })
  end)

  local function texts()
    local out = {}
    for _, c in ipairs(calls) do if c[1] == "DrawList_AddText" then out[#out + 1] = c[6] end end
    return table.concat(out, "\n")
  end

  it("desenha seção, contagem da fila e as linhas, com a grade", function()
    assert.is_true(view.draw("ctx", {
      song = "A", section = "Refrão", bar = 3, bars = 8, next = "Ponte", queued = true, beats_left = 3,
      rows = { { kind = "chords", text = "G   D", current = true }, { kind = "lyrics", text = "letra", current = true },
        { kind = "next", text = "Ponte" }, { kind = "grid", text = "| Am |", cells = { "Am", "D" }, cell = 2 } },
    }))
    local t = texts()
    assert.matches("Refrão", t)
    assert.matches("NA FILA · Ponte em 3 bat%.", t)
    assert.matches("A SEGUIR · PONTE", t)
    assert.matches("letra", t)
    assert.matches("Am", t)
  end)

  it("sem cifra e sem música mostram orientação", function()
    view.draw("ctx", { song = "A", section = "Intro", has_chart = false })
    assert.matches("Esta música não tem cifra", texts())
    calls = {}
    view.draw("ctx", { open = true })
    assert.matches("Nenhuma música", texts())
  end)
end)
