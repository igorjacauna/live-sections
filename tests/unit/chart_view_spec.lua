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
      song = "A", section = "Refrão", bar = 3, bars = 8, progress = 0.3, next = "Ponte", queued = true, beats_left = 3,
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

  local function text_at(t)
    for _, c in ipairs(calls) do if c[1] == "DrawList_AddText" and c[6] == t then return c end end
  end

  it("teleprompter: o ponto de leitura fica perto do meio e a tela rola até ele", function()
    local r = stub.install()
    local rows = {}
    for i = 1, 30 do rows[#rows + 1] = { kind = "lyrics", text = "linha " .. i, past = i < 20 or nil, current = i == 20 or nil } end
    r.set_now(10)
    view.draw("ctx", { song = "A", section = "Verso", rows = rows, focus = 19 })
    local mid = text_at("linha 20")
    assert.is_table(mid)
    assert.is_true(mid[4] > 150 and mid[4] < 400)           -- perto do meio da área
    assert.is_nil(text_at("linha 1"))                        -- bem acima, fora da tela
    -- o ponto avança: no mesmo instante a tela ainda não andou; depois alcança
    calls = {}
    view.draw("ctx", { song = "A", section = "Verso", rows = rows, focus = 21 })
    local y_now = text_at("linha 22")[4]
    calls = {}
    r.set_now(12)
    view.draw("ctx", { song = "A", section = "Verso", rows = rows, focus = 21 })
    assert.near(mid[4], text_at("linha 22")[4], 1)
    assert.is_true(y_now > text_at("linha 22")[4])
  end)

  it("entrar na seção seguinte continua a rolagem: o 'A seguir' vira o cabeçalho no mesmo lugar", function()
    local r = stub.install()
    local verso = {}
    for i = 1, 8 do verso[#verso + 1] = { kind = "lyrics", text = "verso " .. i, current = i >= 7 or nil, past = i < 7 or nil } end
    local function with(list, extra) local out = {} for _, x in ipairs(list) do out[#out + 1] = x end for _, x in ipairs(extra) do out[#out + 1] = x end return out end
    r.set_now(10)
    view.draw("ctx", { song = "A", section = "Verso", focus = 7.9,
      rows = with(verso, { { kind = "next", text = "Refrão" }, { kind = "lyrics", text = "refrão 1" } }) })
    for _ = 1, 3 do r.set_now(r._now + 2); view.draw("ctx", { song = "A", section = "Verso", focus = 7.9,
      rows = with(verso, { { kind = "next", text = "Refrão" }, { kind = "lyrics", text = "refrão 1" } }) }) end
    local before = text_at("refrão 1")[4]
    calls = {}
    -- no Refrão: as últimas 2 linhas do Verso, o cabeçalho e o Refrão
    view.draw("ctx", { song = "A", section = "Refrão", prev = "Verso", focus = 3.05, rows = {
      { kind = "lyrics", text = "verso 7", past = true }, { kind = "lyrics", text = "verso 8", past = true },
      { kind = "header", text = "Refrão" }, { kind = "lyrics", text = "refrão 1", current = true } } })
    assert.near(before, text_at("refrão 1")[4], 1)     -- nada pulou
    assert.is_table(text_at("verso 8"))                 -- a seção anterior continua visível
    assert.matches("REFR", texts())
  end)

  it("linhas que já passaram ficam apagadas", function()
    view.draw("ctx", { song = "A", section = "Verso", focus = 1,
      rows = { { kind = "lyrics", text = "antes", past = true }, { kind = "lyrics", text = "agora", current = true } } })
    assert.are_not.equal(text_at("antes")[5], text_at("agora")[5])
  end)

  it("sem cifra e sem música mostram orientação", function()
    view.draw("ctx", { song = "A", section = "Intro", has_chart = false })
    assert.matches("Esta música não tem cifra", texts())
    calls = {}
    view.draw("ctx", { open = true })
    assert.matches("Nenhuma música", texts())
  end)
end)
