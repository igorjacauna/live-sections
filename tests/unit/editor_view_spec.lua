local stub = require("stubs.reaper")

-- ImGui falsa com estado: guarda o retângulo de cada InvisibleButton e deixa
-- o teste escolher o item ativado, ativo, solto ou clicado e a posição do mouse.
local function fake_imgui()
  local im = {
    MouseButton_Left = 0, MouseButton_Right = 1, Key_S = 83, Key_Z = 90, Key_Enter = 13,
    Mod_Ctrl = 4096, Mod_Shift = 8192, MouseCursor_ResizeEW = 4,
    rects = {}, opts = {}, calls = {},
  }
  local cx, cy, last = 0, 0, nil
  setmetatable(im, { __index = function(_, name)
    return function(...) im.calls[#im.calls + 1] = { name, ... }; return nil end
  end })
  function im.SetCursorScreenPos(_, x, y) cx, cy = x, y end
  function im.InvisibleButton(_, id, w, h)
    im.rects[id] = { x = cx, y = cy, w = w, h = h }
    last = id
    return im.opts.press == id
  end
  function im.InputText(_, id, buf) last = id; return false, buf end
  function im.InputInt(_, id, v) last = id; return false, im.opts.int_value or v end
  function im.IsItemDeactivatedAfterEdit() return im.opts.edited == last end
  function im.IsItemActivated() return im.opts.activate == last end
  function im.IsItemActive() return im.opts.active == last end
  function im.IsItemDeactivated() return im.opts.deactivate == last end
  function im.IsItemHovered() return im.opts.hover == last end
  function im.IsMouseClicked(_, b) return im.opts.mouse_click == b end
  function im.GetMousePos() return im.opts.mx or 0, im.opts.my or 0 end
  function im.IsWindowFocused() return true end
  function im.IsAnyItemActive() return false end
  function im.IsKeyDown(_, k) return im.opts.down == k end
  function im.IsKeyPressed(_, k) return im.opts.key == k end
  function im.BeginPopup() return false end
  function im.GetItemRectSize() return 100, 16 end
  function im.CalcTextSize(_, s) return #s * 7, 14 end
  function im.GetWindowDrawList() return "dl" end
  return im
end

-- 4/4 a 120 BPM: compasso = 2 s. Música A (0–40): Intro 0–8, Verso 8–16,
-- Refrão 16–24 e trecho sem seção 24–40. Música B (40–80) sem seções.
describe("ui.editor_view", function()
  local r, im, view, model, perf, layers, theme, widgets

  local function frame(opts)
    im.opts = opts or {}
    im.calls = {}
    perf.tick()
    view.draw("ctx", 0, 0, 1100, 760, {
      song = model.song_at(r._cursor) and select(1, model.song_at(r._cursor)),
      pos = r._cursor, playing = false,
    })
  end

  local function regions()
    local out = {}
    for _, m in ipairs(r._markers) do
      if m.isrgn then out[#out + 1] = { m.pos, m.rgnend, m.name } end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return out
  end

  -- x na faixa para o instante `t` da música A (0–40 s)
  local function x_at(t)
    local s = im.rects.strip
    return s.x + t / 40 * s.w
  end
  local function lane_y() local s = im.rects.strip; return s.y + s.h - 20 end
  local function ruler_y() return im.rects.strip.y + 5 end

  -- arraste: aperta em t0, solta em t1
  local function drag(t0, t1, y)
    frame({ activate = "strip", active = "strip", mx = x_at(t0), my = y or lane_y() })
    frame({ active = "strip", mx = x_at(t1), my = y or lane_y() })
    frame({ deactivate = "strip", mx = x_at(t1), my = y or lane_y() })
  end

  before_each(function()
    r = stub.install()
    for _, m in ipairs({ "core.project_model", "core.quantize", "core.queue", "core.transport", "core.performance",
      "core.layers", "core.editor_ops", "core.validator", "ui.widgets", "ui.theme", "ui.anim",
      "ui.performance_view", "ui.editor_view" }) do
      package.loaded[m] = nil
    end
    r.set_project_length(80)
    r.add_marker(0, "SONG: A")
    r.add_region(0, 8, "Intro")
    r.add_region(8, 16, "Verso")
    r.add_region(16, 24, "Refrão")
    r.add_marker(40, "SONG: B")
    r.set_config("smoothseekmeas", 1)
    model, perf, layers = require("core.project_model"), require("core.performance"), require("core.layers")
    theme, widgets = require("ui.theme"), require("ui.widgets")
    view = require("ui.editor_view")
    perf.init()
    im = fake_imgui()
    theme.init("ctx", im, "/sem/fontes/")
    widgets.init(im, theme, require("ui.anim"), require("midi.learn"), require("midi.mappings"))
    local pv = require("ui.performance_view")
    pv.init({ ImGui = im, theme = theme, widgets = widgets })
    view.init({
      ImGui = im, theme = theme, widgets = widgets, perf = perf, layers = layers, model = model,
      editor_ops = require("core.editor_ops"), validator = require("core.validator"), kit = pv.kit,
    })
    frame()
  end)

  describe("faixa de estrutura", function()
    it("desenha régua, seções e trecho sem seção", function()
      assert.is_table(im.rects.strip)
      assert.is_table(im.rects.add_song)
      assert.is_nil(im.rects.add_section)
    end)

    it("Selecionar: clicar numa seção seleciona e toca a partir dela", function()
      drag(10, 10)
      assert.equal(8, r._cursor)
      assert.equal("Verso", select(2, model.song_at(r._cursor)).name)
      assert.is_not_nil(view.state().selected)
    end)

    it("Dividir: clicar divide no compasso mais próximo, um passo de undo", function()
      view.state().tool = "split"
      drag(12.2, 12.2)
      assert.same({ { 0, 8, "Intro" }, { 8, 12, "Verso" }, { 12, 16, "Verso 2" }, { 16, 24, "Refrão" } }, regions())
      assert.equal(1, #r.calls_to("Undo_EndBlock"))
    end)

    it("Desenhar: arrastar cria a seção e recorta a vizinha", function()
      view.state().tool = "draw"
      drag(20, 30)
      assert.same({ { 0, 8, "Intro" }, { 8, 16, "Verso" }, { 16, 20, "Refrão" }, { 20, 30, "Seção" } }, regions())
    end)

    it("arrastar na régua desenha; clicar nela move o cursor", function()
      drag(26, 34, ruler_y())
      assert.same({ 26, 34, "Seção" }, regions()[4])
      drag(31, 31, ruler_y())
      assert.equal(32, r._cursor)
    end)

    it("arrastar a borda move as duas seções juntas", function()
      local s = im.rects.strip
      local x = s.x + 8 / 40 * s.w
      frame({ activate = "strip", active = "strip", mx = x + 2, my = lane_y() })
      frame({ deactivate = "strip", mx = x_at(12), my = lane_y() })
      assert.same({ { 0, 12, "Intro" }, { 12, 16, "Verso" }, { 16, 24, "Refrão" } }, regions())
    end)

    it("S divide no cursor", function()
      r._cursor = 4
      frame({ key = im.Key_S })
      assert.same({ 0, 4, "Intro" }, regions()[1])
      assert.same({ 4, 8, "Intro 2" }, regions()[2])
    end)

    it("Ctrl+Z e o botão Desfazer desfazem o último passo", function()
      r._cursor = 4
      frame({ key = im.Key_S })
      frame({ key = im.Key_Z, down = im.Mod_Ctrl })
      assert.equal(1, #r.calls_to("Undo_DoUndo2"))
      r._undo[1] = "Live Sections: dividir seção"
      frame({ press = "undo" })
      assert.equal(2, #r.calls_to("Undo_DoUndo2"))
    end)
  end)

  describe("inspetor", function()
    before_each(function()
      drag(10, 10)  -- seleciona Verso
      frame()
    end)

    it("chip renomeia com a cor do tipo e numera nome repetido", function()
      frame({ press = "chip_Intro" })
      local m = r._markers[3]
      assert.equal("Intro 2", m.name)
      assert.equal(0x1000000 | 0x5B | (0x8D << 8) | (0xEF << 16), m.color)  -- #5B8DEF, cor em uso
    end)

    it("duração digitada em compassos move a borda (e a vizinha encostada)", function()
      frame({ edited = "##sec_len", int_value = 2 })
      assert.same({ { 0, 8, "Intro" }, { 8, 12, "Verso" }, { 12, 24, "Refrão" } }, regions())
    end)

    it("Juntar com a próxima", function()
      frame({ press = "merge" })
      assert.same({ { 0, 8, "Intro" }, { 8, 24, "Verso" } }, regions())
    end)
  end)

  describe("música", function()
    it("+ Seção numa música sem seções cria uma com a música inteira", function()
      r._cursor = 40
      frame()
      assert.is_table(im.rects.add_section)
      frame({ press = "add_section" })
      assert.same({ 40, 80, "Seção" }, regions()[4])
    end)
  end)

  describe("avisos", function()
    it("lista o problema e corrige com um clique", function()
      r.add_region(22, 30, "Ponte")       -- sobrepõe o Refrão (16–24)
      frame()
      assert.equal(1, #view.state().warnings)
      assert.is_table(im.rects.fix1)
      frame({ press = "fix1" })
      assert.same({ 16, 22, "Refrão" }, regions()[3])
    end)
  end)
end)
