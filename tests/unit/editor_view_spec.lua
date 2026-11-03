local stub = require("stubs.reaper")

-- ImGui falsa com estado: guarda o retângulo de cada InvisibleButton e deixa
-- o teste escolher o item ativado, ativo, solto ou clicado e a posição do mouse.
local function fake_imgui()
  local im = {
    MouseButton_Left = 0, MouseButton_Right = 1, Key_S = 83, Key_Z = 90, Key_Enter = 13, Key_Space = 32,
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
  function im.InputText(_, id, buf) last = id; return false, (im.opts.text and im.opts.text[id]) or buf end
  function im.InputInt(_, id, v) last = id; return false, im.opts.int_value or v end
  function im.IsItemDeactivatedAfterEdit() return im.opts.edited == last end
  function im.IsItemActivated() return im.opts.activate == last end
  function im.IsItemActive() return im.opts.active == last end
  function im.IsItemDeactivated() return im.opts.deactivate == last end
  function im.IsItemHovered() return im.opts.hover == last end
  function im.IsMouseClicked(_, b) return im.opts.mouse_click == b end
  function im.IsMouseDoubleClicked() return im.opts.double == true end
  function im.GetMousePos() return im.opts.mx or 0, im.opts.my or 0 end
  function im.GetMouseWheel() return im.opts.wheel or 0, im.opts.wheel_h or 0 end
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
  local r, im, view, model, perf, layers, theme, widgets, wiz, lib_view

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
      "core.layers", "core.editor_ops", "core.validator", "core.tempo_align", "ui.widgets", "ui.theme", "ui.anim",
      "ui.performance_view", "ui.editor_view", "ui.kontakt_wizard", "ui.library_view" }) do
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
    wiz = require("ui.kontakt_wizard")
    wiz.init({ ImGui = im, theme = theme, layers = layers, kit = pv.kit })
    lib_view = require("ui.library_view")
    lib_view.init({ ImGui = im, theme = theme, kit = pv.kit, library = {},
      song_package = { detect_tracks = function() return {} end } })
    view.init({
      ImGui = im, theme = theme, widgets = widgets, perf = perf, layers = layers, model = model,
      editor_ops = require("core.editor_ops"), validator = require("core.validator"),
      tempo_align = require("core.tempo_align"), kontakt_wizard = wiz, kit = pv.kit,
      library_view = lib_view,
    })
    frame()
  end)

  describe("faixa de estrutura", function()
    it("desenha régua, seções e trecho sem seção", function()
      assert.is_table(im.rects.strip)
      assert.is_table(im.rects.add_song)
      assert.is_nil(im.rects.add_section)
    end)

    it("Selecionar: clicar numa seção seleciona e leva o cursor ao início, sem tocar", function()
      drag(10, 10)
      assert.equal(8, r._cursor)
      assert.is_not_nil(view.state().selected)
      assert.equal(0, #r.calls_to("OnPlayButton"))
    end)

    it("clicar de novo na seção selecionada põe o cursor no compasso clicado", function()
      drag(10, 10)
      assert.equal(8, r._cursor)
      drag(13, 13)
      assert.equal(12, r._cursor)
      assert.equal(0, #r.calls_to("OnPlayButton"))
    end)

    it("duplo clique numa seção toca a partir dela", function()
      frame({ activate = "strip", active = "strip", mx = x_at(10), my = lane_y() })
      frame({ deactivate = "strip", mx = x_at(10), my = lane_y(), double = true })
      assert.equal(8, r._cursor)
      assert.equal(1, r._play_state)
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

    it("ímã: perto da borda de uma seção, o desenho gruda nela (não no compasso)", function()
      -- música B longa (40–440 s): 1 compasso < 10 px, o ímã alcança mais que o compasso
      r.set_project_length(440)
      r.add_region(40, 100, "Intro B")
      r._cursor = 40
      frame()
      view.state().tool = "draw"
      local s = im.rects.strip
      local function bx(t) return s.x + (t - 40) / 400 * s.w end
      frame({ activate = "strip", active = "strip", mx = bx(103), my = lane_y() })
      frame({ deactivate = "strip", mx = bx(150), my = lane_y() })
      assert.same({ 100, 150, "Seção" }, regions()[5])
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

    it("Desfazer com nome longo corta o rótulo dentro do botão", function()
      r._undo[1] = "Edit FX parameter: Track 3 Kontakt: Live Sections - Mapeamento do Kontakt"
      frame()
      local b = im.rects.undo
      local found
      for _, c in ipairs(im.calls) do
        if c[1] == "DrawList_AddText" and c[3] >= b.x and c[3] < b.x + b.w and c[4] >= b.y and c[4] < b.y + b.h then
          found = c
        end
      end
      assert.is_not_nil(found)
      assert.truthy(found[6]:find("…$"))
      assert.truthy(found[3] + #found[6] * 7 <= b.x + b.w)
    end)
  end)

  describe("grade", function()
    after_each(function() require("core.editor_ops").set_grid("bar") end)

    it("os botões trocam a grade e ela fica salva; dividir no tempo cai entre compassos", function()
      assert.is_table(im.rects.grid_beat)
      frame({ press = "grid_beat" })
      assert.equal("beat", require("core.editor_ops").grid())
      assert.equal("beat", reaper.GetExtState("LiveSections", "editor_grid"))
      r._cursor = 9.4
      frame({ key = im.Key_S })
      assert.same({ 8, 9.5, "Verso" }, regions()[2])
      assert.matches("compasso 5, tempo 4", view.state().status)
    end)
  end)

  describe("zoom da faixa", function()
    local function v() return view.state().view end
    local function strip_x(frac) local s = im.rects.strip; return s.x + frac * s.w end

    it("começa com a música inteira e o mini-mapa", function()
      assert.same({ 0, 40 }, { v().t0, v().span })
      assert.is_table(im.rects.minimap)
      assert.is_table(im.rects.zoom_in)
    end)

    it("Ctrl+roda dá zoom mantendo o ponto do mouse no lugar", function()
      frame({ hover = "strip", down = im.Mod_Ctrl, wheel = 2, mx = strip_x(0.25), my = lane_y() })
      assert.near(40 / 2.25, v().span, 1e-9)
      assert.near(0.25, (10 - v().t0) / v().span, 1e-9)
      local claimed = false
      for _, c in ipairs(im.calls) do if c[1] == "SetItemKeyOwner" then claimed = true end end
      assert.is_true(claimed)
    end)

    it("a roda só rola com zoom, e não sai da música", function()
      frame({ hover = "strip", wheel = -1, mx = strip_x(0.5), my = lane_y() })
      assert.same({ 0, 40 }, { v().t0, v().span })
      frame({ press = "zoom_in" })
      frame({ press = "zoom_in" })
      local t0 = v().t0
      frame({ hover = "strip", wheel = -1, mx = strip_x(0.5), my = lane_y() })
      assert.near(t0 + v().span * 0.1, v().t0, 1e-9)
      for _ = 1, 30 do frame({ hover = "strip", wheel = -3, mx = strip_x(0.5), my = lane_y() }) end
      assert.near(40 - v().span, v().t0, 1e-9)
    end)

    it("+ aproxima até 2 compassos; − e Inteira voltam", function()
      for _ = 1, 10 do frame({ press = "zoom_in" }) end
      assert.near(4, v().span, 1e-9)                   -- 2 compassos de 2 s
      frame({ press = "zoom_out" })
      assert.near(6, v().span, 1e-9)
      frame({ press = "zoom_all" })
      assert.same({ 0, 40 }, { v().t0, v().span })
    end)

    it("com zoom, clicar na faixa usa o trecho visível", function()
      frame({ press = "zoom_in" })
      frame({ press = "zoom_in" })                       -- 17,8 s centrados em 20 s
      local t0 = v().t0
      assert.near(20 - 40 / 2.25 / 2, t0, 1e-9)
      frame({ activate = "strip", active = "strip", mx = strip_x(0), my = lane_y() })
      frame({ deactivate = "strip", mx = strip_x(0), my = lane_y() })
      assert.equal(8, r._cursor)                          -- Verso (8–16)
    end)

    it("arrastar no mini-mapa centra o trecho visível no mouse", function()
      frame({ press = "zoom_in" })
      frame({ press = "zoom_in" })
      local m = im.rects.minimap
      frame({ active = "minimap", mx = m.x + m.w * 0.6 })
      assert.near(24 - v().span / 2, v().t0, 1e-9)
    end)

    it("tocando, acompanha o cursor que sai do trecho visível", function()
      for _ = 1, 4 do frame({ press = "zoom_in" }) end   -- 7,9 s centrados em 20 s
      local function play_at(pos)
        im.opts, im.calls = {}, {}
        view.draw("ctx", 0, 0, 1100, 760, { song = model.songs()[1], pos = pos, playing = true })
      end
      play_at(20)
      play_at(25)
      assert.near(25 - v().span * 0.1, v().t0, 1e-9)
    end)

    it("trocar de música volta para a música inteira", function()
      frame({ press = "zoom_in" })
      im.opts, im.calls = {}, {}
      view.draw("ctx", 0, 0, 1100, 760, { song = model.songs()[2], pos = 40, playing = false })
      assert.same({ 40, 40 }, { v().t0, v().span })
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

    it("Remover deixa o trecho sem seção", function()
      frame({ press = "remove" })
      assert.same({ { 0, 8, "Intro" }, { 16, 24, "Refrão" } }, regions())
      assert.is_nil(view.state().selected)
    end)

    it("botão: toca da seção, pausa, continua; Stop para", function()
      frame({ press = "play_from" })
      assert.equal(1, r._play_state)
      assert.equal(8, r._cursor)
      frame({ press = "play_from" })
      assert.equal(2, r._play_state)
      frame({ press = "play_from" })
      assert.equal(1, r._play_state)
      frame({ press = "stop" })
      assert.equal(0, r._play_state)
    end)

    it("Espaço toca da seção e para; com o cursor dentro dela, toca do cursor", function()
      frame({ key = im.Key_Space })
      assert.equal(1, r._play_state)
      assert.equal(8, r._cursor)
      frame({ key = im.Key_Space })
      assert.equal(0, r._play_state)
      r._cursor = 13
      frame({ key = im.Key_Space })
      assert.equal(13, r._cursor)
      assert.equal(1, r._play_state)
      assert.matches("Verso, compasso 7", view.state().status)
    end)

    it("com o cursor em outra seção, toca do cursor e seleciona a seção dele", function()
      local verso = view.state().selected
      r._cursor = 20
      frame({ press = "play_from" })
      assert.equal(20, r._cursor)
      assert.equal(1, r._play_state)
      assert.are_not.equal(verso, view.state().selected)
      assert.matches("Refrão, compasso 11", view.state().status)
    end)

    it("com o cursor num trecho sem seção, toca do cursor", function()
      r._cursor = 30
      frame({ key = im.Key_Space })
      assert.equal(30, r._cursor)
      assert.equal(1, r._play_state)
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

  describe("tempo", function()
    it("tap: 4 toques dão o BPM; Marcar compasso 1 usa o BPM medido no cursor", function()
      for i = 0, 3 do r.set_now(10 + i * 0.5); frame({ press = "tap" }) end
      assert.equal(120, view.state().tap_bpm)
      r._cursor = 3
      frame({ press = "mark_bar1" })
      local at3
      for _, m in ipairs(r._tempo_markers) do if math.abs(m.time - 3) < 1e-9 then at3 = m end end
      assert.near(120, at3.bpm, 1e-9)
      assert.equal(4, at3.num)
    end)

    it("tap_tempo mapeável chega pelo M.tap", function()
      for i = 0, 3 do r.set_now(i * 0.6); view.tap() end
      assert.equal(100, view.state().tap_bpm)
    end)

    local function tempo_marker_at(t)
      for _, m in ipairs(r._tempo_markers) do if math.abs(m.time - t) < 1e-9 then return m end end
    end

    it("+0,01 sem compasso 1 marcado muda o BPM da música e avisa no painel", function()
      frame({ press = "bpm_up" })
      assert.near(120.01, tempo_marker_at(0).bpm, 1e-9)
      assert.equal(0, tempo_marker_at(0).num)
      assert.matches("BPM da música: 120,01", view.state().tempo_msg.text)
      assert.is_false(view.state().tempo_msg.err)
    end)

    it("mover o compasso 1 sem ele marcado avisa no painel", function()
      frame({ press = "ms_up" })
      assert.matches("Marque o compasso 1", view.state().tempo_msg.text)
      assert.is_true(view.state().tempo_msg.err)
    end)

    it("digitar o BPM (com vírgula) aplica ao sair do campo", function()
      frame({ text = { ["##song_bpm"] = "95,5" }, edited = "##song_bpm" })
      assert.near(95.5, tempo_marker_at(0).bpm, 1e-9)
      assert.equal("95,5", view.state().bpm_buf)
      frame({ text = { ["##song_bpm"] = "abc" }, edited = "##song_bpm" })
      assert.matches("entre 20 e 400", view.state().tempo_msg.text)
      frame()
      assert.equal("95,5", view.state().bpm_buf)
    end)

    it("a fórmula troca pelo painel e marca a atual", function()
      frame({ press = "sig_3_4" })
      local m = tempo_marker_at(0)
      assert.same({ 3, 4 }, { m.num, m.denom })
      assert.matches("Fórmula da música: 3/4", view.state().tempo_msg.text)
    end)

    it("a fórmula pode ser digitada; inválida avisa e volta à atual", function()
      frame({ text = { ["##song_sig"] = " 11 / 16 " }, edited = "##song_sig" })
      local m = tempo_marker_at(0)
      assert.same({ 11, 16 }, { m.num, m.denom })
      frame()
      assert.equal("11/16", view.state().sig_buf)
      frame({ text = { ["##song_sig"] = "7/3" }, edited = "##song_sig" })
      assert.matches("Digite a fórmula como 7/8", view.state().tempo_msg.text)
      frame()
      assert.equal("11/16", view.state().sig_buf)
    end)

    it("metrônomo liga pela ação do REAPER", function()
      frame({ press = "metronome" })
      local cmds = {}
      for _, c in ipairs(r.calls_to("Main_OnCommand")) do cmds[c[1]] = true end
      assert.is_true(cmds[40364])
    end)
  end)

  describe("Kontakt", function()
    it("o cartão abre o assistente, que sugere a track com Kontakt", function()
      r.add_track("Teclas").fx = { "VSTi: Kontakt 7" }
      frame({ press = "kontakt_wizard" })
      local opened = false
      for _, c in ipairs(im.calls) do if c[1] == "OpenPopup" and c[3] == "Assistente de Kontakt" then opened = true end end
      assert.is_true(opened)
    end)
  end)

  describe("Exportar", function()
    it("o botão da barra de músicas abre o quadro para a música atual", function()
      frame({ press = "export_song" })
      local opened = false
      for _, c in ipairs(im.calls) do if c[1] == "OpenPopup" and c[3] == "Exportar música" then opened = true end end
      assert.is_true(opened)
      assert.equal("A", lib_view.export_state().song.name)
    end)

    it("a barra de músicas também tem + Da biblioteca", function()
      assert.is_table(im.rects.from_library)
      assert.is_true(im.rects.from_library.x + im.rects.from_library.w <= im.rects.add_song.x)
      assert.is_true(im.rects.export_song.x + im.rects.export_song.w <= im.rects.from_library.x)
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
