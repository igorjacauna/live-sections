local stub = require("stubs.reaper")

-- ImGui falsa: aceita qualquer chamada. `opts`: press (botão apertado),
-- hover (botão sob o mouse), dbl (duplo clique), popup (popup aberto),
-- text (o que foi digitado), button (ImGui.Button clicado).
local function fake_imgui(opts)
  opts = opts or {}
  local calls = {}
  local last
  local im = { MouseButton_Left = 0, MouseButton_Right = 1, Key_Escape = 512, DrawFlags_RoundCornersTop = 48 }
  setmetatable(im, { __index = function(_, name)
    return function(...) calls[#calls + 1] = { name, ... }; return 0, 0 end
  end })
  function im.InvisibleButton(_, id, w, h)
    calls[#calls + 1] = { "InvisibleButton", id, w, h }
    last = id
    return opts.press == id
  end
  function im.IsItemClicked() return false end
  function im.IsItemHovered() return opts.hover ~= nil and opts.hover == last end
  function im.IsMouseDoubleClicked() return opts.dbl == true end
  function im.IsItemActive() return false end
  function im.BeginPopup(_, id) return opts.popup == id end
  function im.InputText(_, _, v) if opts.text then return true, opts.text end return false, v end
  function im.Button(_, label) return opts.button == label end
  function im.IsKeyPressed() return false end
  function im.GetContentRegionAvail() return opts.w or 1100, opts.h or 760 end
  function im.GetCursorScreenPos() return 0, 0 end
  function im.CalcTextSize(_, s) return #s * 7, 14 end
  function im.GetDeltaTime() return 1 / 60 end
  return im, calls
end

-- 4/4 a 120 BPM: compasso = 2 s. Música A (0–40) com 3 seções; B (40–80) sem seções.
describe("ui.performance_view", function()
  local r, view, perf, layers, mappings, learn, input, feedback, widgets, theme, anim, model, dir
  local MASTER, KEYS = "SMC-Mixer-Master", "Keys"

  local function load(im)
    widgets.init(im, theme, anim, learn, mappings)
    view.init({
      ImGui = im, theme = theme, anim = anim, widgets = widgets, perf = perf, layers = layers,
      feedback = feedback, mappings = mappings, learn = learn, input = input, model = model,
    })
  end

  local function ev(status, d1, d2, port) return { port_name = port or MASTER, status = status, data1 = d1, data2 = d2 } end

  before_each(function()
    r = stub.install()
    dir = os.tmpname(); os.remove(dir)
    r._resource_path = dir
    for _, m in ipairs({ "core.project_model", "core.quantize", "core.queue", "core.transport", "core.performance",
      "core.layers", "midi.mappings", "midi.learn", "midi.input", "midi.feedback", "ui.widgets", "ui.theme",
      "ui.anim", "ui.performance_view" }) do
      package.loaded[m] = nil
    end
    r.set_project_length(80)
    r.add_marker(0, "SONG: A")
    r.add_region(0, 8, "Intro")
    r.add_region(8, 16, "Verso")
    r.add_region(16, 24, "Refrão")
    r.add_marker(40, "SONG: B")
    r.set_config("smoothseekmeas", 1)
    r.add_midi_input(4, MASTER)
    r.add_midi_input(5, KEYS)
    r.add_midi_output(4, MASTER)
    model, perf, layers = require("core.project_model"), require("core.performance"), require("core.layers")
    mappings, learn, input = require("midi.mappings"), require("midi.learn"), require("midi.input")
    feedback, widgets = require("midi.feedback"), require("ui.widgets")
    theme, anim, view = require("ui.theme"), require("ui.anim"), require("ui.performance_view")
    mappings.load()
    input.init()
    feedback.configure({ led_velocity = { idle = 0, playing = 127, queued = 60, loop = 90, empty = 0 }, led_blink = false })
    layers.configure({ keyboard_port = KEYS })
    perf.init()
    local im = fake_imgui()
    theme.init("ctx", im, "/sem/fontes/")
    load(im)
  end)

  after_each(function() os.execute("rm -rf '" .. dir .. "'") end)

  describe("ações", function()
    it("run executa as ações mapeáveis", function()
      assert.equal("started", view.run("trigger_slot", 2))
      assert.equal(8, r._cursor)
      assert.is_true(view.run("set_quantize", "4bar"))
      assert.equal("4bar", perf.quantize())
      view.run("cycle_quantize", 1)
      assert.equal("8bar", perf.quantize())
      assert.is_true(view.run("toggle_setlist"))
      assert.is_true(view.ui().setlist_open)
    end)

    it("controle do Mapeamento vai para o kontakt_cc, inclusive o soltar", function()
      local got = {}
      local kcc = { handle = function(m, value, released) got[#got + 1] = { m.arg, value, released or false } end,
        on_song = function() end, tick = function() end }
      view.init({
        ImGui = fake_imgui(), theme = theme, anim = anim, widgets = widgets, perf = perf, layers = layers,
        feedback = feedback, mappings = mappings, learn = learn, input = input, model = model, kontakt_cc = kcc,
      })
      mappings.set({ action = "kontakt_cc", arg = "k1", port_name = MASTER, msg_type = "note", channel = 1, number = 30 })
      view.handle_event(ev(0x90, 30, 127))
      view.handle_event(ev(0x80, 30, 0))
      assert.same({ { "k1", 1, false }, { "k1", 0, true } }, got)
      assert.equal(0, r._cursor)
    end)

    it("ao trocar de música avisa o kontakt_cc depois do activate e roda o tick", function()
      local log = {}
      local kcc = { handle = function() end, on_song = function(song) log[#log + 1] = "song:" .. song.name end,
        tick = function(t) log[#log + 1] = "tick:" .. t end }
      local activate = layers.activate
      layers.activate = function(...) log[#log + 1] = "activate"; return activate(...) end
      view.init({
        ImGui = fake_imgui(), theme = theme, anim = anim, widgets = widgets, perf = perf, layers = layers,
        feedback = feedback, mappings = mappings, learn = learn, input = input, model = model, kontakt_cc = kcc,
      })
      view.update(1)
      view.update(2)
      assert.same({ "activate", "song:A", "tick:1", "tick:2" }, log)
    end)

    it("num ciclo, de cada fader e knob absoluto só a última mensagem conta", function()
      local got = {}
      local kcc = { handle = function(m, value) got[#got + 1] = { m.arg, math.floor(value * 127 + 0.5) } end,
        on_song = function() end, tick = function() end, absolute = function(id) return id == "k1" end }
      view.init({
        ImGui = fake_imgui(), theme = theme, anim = anim, widgets = widgets, perf = perf, layers = layers,
        feedback = feedback, mappings = mappings, learn = learn, input = input, model = model, kontakt_cc = kcc,
      })
      mappings.set({ action = "kontakt_cc", arg = "k1", port_name = MASTER, msg_type = "cc", channel = 1, number = 16 })
      mappings.set({ action = "kontakt_cc", arg = "k2", port_name = MASTER, msg_type = "cc", channel = 1, number = 17 })
      local vols = {}
      local set = layers.set_layer_volume
      layers.set_layer_volume = function(slot, v) vols[#vols + 1] = v; return set(slot, v) end
      mappings.set({ action = "layer_volume", arg = 1, port_name = MASTER, msg_type = "pb", channel = 1 })
      for v = 1, 40 do r.midi_in(4, 0xB0, 16, v) end   -- knob absoluto
      for _ = 1, 3 do r.midi_in(4, 0xB0, 17, 1) end    -- knob sem fim: cada passo conta
      for v = 0, 100, 10 do r.midi_in(4, 0xE0, 0, v) end
      view.update(1)
      assert.same({ { "k1", 40 }, { "k2", 1 }, { "k2", 1 }, { "k2", 1 } }, got)
      assert.same({ ((100 << 7) | 0) / 16383 }, vols)
    end)

    it("evento mapeado dispara a ação e pisca o controle; Note Off não dispara", function()
      mappings.set({ action = "trigger_slot", arg = 3, port_name = MASTER, msg_type = "note", channel = 1, number = 24 })
      view.handle_event(ev(0x80, 24, 0))
      assert.equal(0, r._cursor)
      view.handle_event(ev(0x90, 24, 127))
      assert.equal(16, r._cursor)
    end)

    it("botão em CC dispara só na subida", function()
      mappings.set({ action = "next_song", port_name = MASTER, msg_type = "cc", channel = 1, number = 20 })
      local n = 0
      perf.next_song = function() n = n + 1 end
      view.handle_event(ev(0xB0, 20, 127))
      view.handle_event(ev(0xB0, 20, 127))
      view.handle_event(ev(0xB0, 20, 0))
      view.handle_event(ev(0xB0, 20, 127))
      assert.equal(2, n)
    end)

    it("botão em CC que só manda o valor alto: cada toque conta", function()
      mappings.set({ action = "play_stop", port_name = MASTER, msg_type = "cc", channel = 1, number = 21 })
      local n = 0
      perf.play_stop = function() n = n + 1 end
      view.update(1)
      view.handle_event(ev(0xB0, 21, 127))
      view.update(2)
      view.handle_event(ev(0xB0, 21, 127))
      assert.equal(2, n)
    end)

    it("Play e Stop em botões separados", function()
      mappings.set({ action = "play", port_name = MASTER, msg_type = "note", channel = 1, number = 94 })
      mappings.set({ action = "stop", port_name = MASTER, msg_type = "note", channel = 1, number = 93 })
      assert.is_truthy(mappings.get("play") and mappings.get("stop"))
      view.handle_event(ev(0x90, 94, 127))
      assert.equal(1, #r.calls_to("OnPlayButton"))
      r._play_state = 1
      view.handle_event(ev(0x90, 93, 127))
      assert.equal(1, #r.calls_to("OnStopButton"))
    end)

    it("fader em pitch bend segue o valor", function()
      mappings.set({ action = "layer_volume", arg = 1, port_name = MASTER, msg_type = "pb", channel = 1 })
      local got = {}
      layers.set_layer_volume = function(slot, v) got[#got + 1] = { slot, v } end
      view.handle_event(ev(0xE0, 0, 0x40))
      view.handle_event(ev(0xE0, 0, 0x20))
      assert.equal(2, #got)
      assert.near(0x20 * 128 / 16383, got[2][2], 1e-9)
    end)

    it("durante o learn o evento vira mapeamento e não dispara ação", function()
      learn.start({ action = "trigger_slot", arg = 2 })
      view.handle_event(ev(0x90, 30, 127))
      assert.equal(0, r._cursor)
      assert.equal(30, mappings.get("trigger_slot", 2).number)
    end)

    it("notas do teclado chegam ao controle de notas seguradas", function()
      view.handle_event(ev(0x90, 60, 100, KEYS))
      assert.is_true(layers.held())
    end)
  end)

  describe("update", function()
    it("estado dos cards: tocando, na fila com batidas restantes, loop", function()
      r.set_play(true, 9)
      view.update(0)
      local s = view.snapshot()
      assert.equal("Verso", s.section.name)
      assert.near(1 / 8, s.progress, 1e-9)
      assert.equal("playing", view.card_state(s.section, s))

      perf.trigger_slot(3)                   -- quantize 1 compasso: virada em 10 s
      view.update(0.1)
      s = view.snapshot()
      assert.equal("queued", view.card_state(model.songs()[1].sections[3], s))
      assert.equal(2, s.beats_left)          -- 9 s → 10 s: 2 batidas de 0,5 s
    end)

    it("acende os LEDs pelo estado e apaga pad sem seção", function()
      mappings.set({ action = "trigger_slot", arg = 2, port_name = MASTER, msg_type = "note", channel = 1, number = 24 })
      mappings.set({ action = "trigger_slot", arg = 9, port_name = MASTER, msg_type = "note", channel = 1, number = 25 })
      r.set_play(true, 9)
      view.update(0)
      local leds = {}
      for _, c in ipairs(r.calls_to("StuffMIDIMessage")) do leds[c[3]] = c[4] end
      assert.same({ [24] = 127, [25] = 0 }, leds)
    end)

    it("LEDs de mute e solo das camadas seguem o estado da track", function()
      local k = r.add_track("Kontakt A")
      local piano = r.add_track("Piano")
      r.add_receive(k, piano, 0)
      layers.link(model.songs()[1], k)
      mappings.set({ action = "layer_mute", arg = 1, port_name = MASTER, msg_type = "note", channel = 1, number = 16 })
      mappings.set({ action = "layer_solo", arg = 1, port_name = MASTER, msg_type = "note", channel = 1, number = 8 })
      view.update(0)
      view.handle_event(ev(0x90, 16, 127))
      view.update(0.1)
      local leds = {}
      for _, c in ipairs(r.calls_to("StuffMIDIMessage")) do leds[c[3]] = c[4] end
      assert.same({ [16] = 127, [8] = 0 }, leds)
      assert.equal(1, piano.info.B_MUTE)
    end)

    it("troca de música ativa as camadas da nova música", function()
      local seen = {}
      layers.activate = function(song) seen[#seen + 1] = song and song.name end
      view.update(0)
      view.update(0.1)
      r.set_play(false)
      r._cursor = 41
      view.update(0.2)
      assert.same({ "A", "B" }, seen)
    end)

    it("porta mapeada que some aparece como desconectada", function()
      mappings.set({ action = "panic", port_name = MASTER, msg_type = "note", channel = 1, number = 1 })
      view.update(0)
      assert.same({}, view.snapshot().disconnected)
      r.set_midi_present(4, false)
      view.update(0.5)
      assert.same({}, view.snapshot().disconnected)       -- checa a cada 1 s
      view.update(1.2)
      assert.same({ MASTER }, view.snapshot().disconnected)
    end)
  end)

  describe("draw", function()
    local function draw(opts)
      local im, calls = fake_imgui(opts)
      load(im)
      if opts and opts.setup then opts.setup() end
      view.update(1)
      assert.has_no.errors(function() view.draw("ctx") end)
      return calls
    end

    local function ids(calls)
      local out = {}
      for _, c in ipairs(calls) do if c[1] == "InvisibleButton" then out[c[2]] = true end end
      return out
    end

    it("desenha barra superior, setlist, cards, camadas e ações", function()
      local b = ids(draw())
      assert.is_true(b.mode_perf and b.mode_edit and b.stage and b.quantize)
      assert.is_true(b.song1 and b.song2)
      assert.is_true(b["sec" .. model.songs()[1].sections[1].region_idx])
      assert.is_true(b.act_toggle_loop and b.act_cancel and b.act_play and b.act_stop and b.act_prev_song and b.act_next_song)
    end)

    describe("aviso do Mapeamento", function()
      local function draw_touch(touch, stage, mode)
        local im, calls = fake_imgui()
        local kcc = { handle = function() end, on_song = function() end, tick = function() end, led = function() end,
          last_touch = function() return touch end }
        widgets.init(im, theme, anim, learn, mappings)
        view.init({
          ImGui = im, theme = theme, anim = anim, widgets = widgets, perf = perf, layers = layers,
          feedback = feedback, mappings = mappings, learn = learn, input = input, model = model, kontakt_cc = kcc,
        })
        view.ui().stage = stage or false
        view.ui().mode = mode or "performance"
        view.update(1)
        view.draw("ctx")
        local texts = {}
        for _, c in ipairs(calls) do if c[1] == "DrawList_AddText" then texts[c[6]] = true end end
        return texts
      end

      it("mostra nome e valor do knob em Performance e Palco", function()
        local touch = { row = { name = "Cutoff", kind = "knob" }, value = 64 }
        assert.is_true(draw_touch(touch)["Cutoff  64"])
        assert.is_true(draw_touch(touch, true)["Cutoff  64"])
      end)

      it("botão mostra ON ou OFF", function()
        assert.is_true(draw_touch({ row = { name = "Rotary", kind = "toggle" }, value = 127 })["Rotary  ON"])
        assert.is_true(draw_touch({ row = { name = "Rotary", kind = "toggle" }, value = 0 })["Rotary  OFF"])
      end)

      it("sem toque recente não mostra nada", function()
        local texts = draw_touch(nil)
        for t in pairs(texts) do assert.is_nil(t:find("  64", 1, true)) end
      end)

      it("não aparece em Configurações", function()
        local touch = { row = { name = "Cutoff", kind = "knob" }, value = 64 }
        assert.is_nil(draw_touch(touch, false, "settings")["Cutoff  64"])
      end)
    end)

    it("botão Mapeamento abre a tela; sair dela para o learn em série", function()
      local b = ids(draw())
      assert.is_true(b.mode_mapping)
      draw({ press = "mode_mapping" })
      assert.equal("mapping", view.ui().mode)
      learn.start_series(function() end)
      draw({ press = "mode_mapping" })
      assert.equal("series", learn.state().mode)
      draw({ press = "mode_perf" })
      assert.is_nil(learn.state())
      assert.equal("performance", view.ui().mode)
    end)

    it("o learn do Mapeamento que recusa um controle deixa o conflito para a tela", function()
      mappings.set({ action = "panic", port_name = MASTER, msg_type = "note", channel = 1, number = 5 })
      learn.start_series(function() end)
      view.update(3)
      view.handle_event(ev(0x90, 5, 127))
      assert.equal("panic", view.ui().learn_conflict.mapping.action)
    end)

    it("modo palco: faixa compacta e setlist expansível", function()
      local b = ids(draw({ setup = function() view.ui().stage = true end }))
      assert.is_true(b.strip1 and b.strip2 and b.strip3)
      assert.is_nil(b.song1)
      b = ids(draw({ setup = function() view.ui().stage = true; view.ui().setlist_open = true end }))
      assert.is_true(b.song1)
    end)

    it("janela estreita usa a faixa compacta", function()
      local b = ids(draw({ w = 600 }))
      assert.is_true(b.strip2)
    end)

    it("música sem seções mostra a orientação e + Seção, que leva ao modo Editar", function()
      local b = ids(draw({ setup = function() r._cursor = 50 end }))
      assert.is_true(b.add_section)
      draw({ press = "add_section", setup = function() r._cursor = 50 end })
      assert.equal("edit", view.ui().mode)
    end)

    it("o botão Play da barra de ações toca", function()
      draw({ press = "act_play" })
      assert.equal(1, #r.calls_to("OnPlayButton"))
      r._play_state = 1
      draw({ press = "act_play" })
      assert.equal(1, #r.calls_to("OnPlayButton"))     -- tocando, Play não reinicia
      draw({ press = "act_stop" })
      assert.equal(1, #r.calls_to("OnStopButton"))
    end)

    it("Kontakt vinculado sem teclado escolhido: desenha as camadas sem erro", function()
      layers.configure({})
      local k = r.add_track("Kontakt A")
      r.add_receive(k, r.add_track("Piano"), 0)
      layers.link(model.songs()[1], k)
      local b = ids(draw())
      assert.is_true(b.fader1)
      assert.equal("Piano", layers.layer_state(1).name)
    end)

    it("mostra a versão no topo, igual ao arquivo VERSION", function()
      local f = assert(io.open("VERSION"))
      local version = f:read("a"):gsub("%s+", "")
      f:close()
      assert.equal(version, require("version"))
      local shown = false
      for _, c in ipairs(draw()) do if c[1] == "DrawList_AddText" and c[6] == "v" .. version then shown = true end end
      assert.is_true(shown)
    end)

    it("botão maximizar pede para maximizar/restaurar", function()
      draw({ press = "maximize" })
      assert.is_true(view.ui().toggle_max)
    end)

    it("camada com som: medidor estéreo em verde, âmbar ou vermelho conforme o nível", function()
      local k = r.add_track("Kontakt A")
      local piano = r.add_track("Piano", nil, k)
      piano.peak = { 0.5, 1.2 }                 -- -6 dB e +1,6 dB
      layers.link(model.songs()[1], k)
      local calls = draw()
      local colors = {}
      for _, c in ipairs(calls) do
        if c[1] == "DrawList_AddRectFilled" then colors[c[7]] = true end
      end
      local theme = require("ui.theme")
      assert.is_true(colors[theme.C.ok] and colors[theme.C.queue] and colors[theme.C.danger])
    end)

    it("modo palco: camadas com fader vertical mais baixo, mute e solo", function()
      local k = r.add_track("Kontakt A")
      r.add_receive(k, r.add_track("Piano"), 0)
      layers.link(model.songs()[1], k)
      local calls = draw({ setup = function() view.ui().stage = true end })
      local b = ids(calls)
      assert.is_true(b.fader1 and b.mute1 and b.solo1)
      local fader
      for _, c in ipairs(calls) do if c[1] == "InvisibleButton" and c[2] == "fader1" then fader = c end end
      assert.is_true(fader[4] > fader[3])          -- mais alto que largo
      assert.is_true(fader[4] < 132)               -- mais baixo que no Performance
    end)

    it("duplo clique no nome renomeia a camada desta música", function()
      local k = r.add_track("Kontakt A")
      local piano = r.add_track("Piano")
      r.add_receive(k, piano, 0)
      layers.link(model.songs()[1], k)
      local calls = draw({ hover = "lname1", dbl = true })
      local opened = false
      for _, c in ipairs(calls) do if c[1] == "OpenPopup" and c[3] == "rename_layer" then opened = true end end
      assert.is_true(opened)
      draw({ popup = "rename_layer", text = "  Piano elétrico ", button = "Renomear" })
      assert.equal("Piano elétrico", piano.name)
      draw({ popup = "rename_layer", text = "Outro", button = "Renomear" })
      assert.equal("Piano elétrico", piano.name)    -- popup já fechado
    end)

    it("modo palco: sem camadas, nada de camadas aparece", function()
      local calls = draw({ setup = function() view.ui().stage = true end })
      for _, c in ipairs(calls) do assert.is_not.equal("CAMADAS", c[1] == "DrawList_AddText" and c[6]) end
    end)

    it("Espaço dá Play/Stop no Performance, fora de campos de texto", function()
      local function press_space(active)
        local im = fake_imgui()
        function im.IsWindowFocused() return true end
        function im.IsAnyItemActive() return active end
        function im.IsKeyDown() return false end
        function im.IsKeyPressed(_, key) return key == "space" end
        im.Key_Space = "space"
        load(im)
        view.update(1)
        view.draw("ctx")
      end
      press_space(true)
      assert.equal(0, #r.calls_to("OnPlayButton"))
      press_space(false)
      assert.equal(1, #r.calls_to("OnPlayButton"))
    end)

    it("anotação da música aparece no Performance e no Palco", function()
      local stage = require("core.stage")
      require("core.song_notes").set(model.songs()[1], "Tom: G")
      for _, on_stage in ipairs({ false, true }) do
        local im, calls = fake_imgui()
        widgets.init(im, theme, anim, learn, mappings)
        view.init({
          ImGui = im, theme = theme, anim = anim, widgets = widgets, perf = perf, layers = layers,
          feedback = feedback, mappings = mappings, learn = learn, input = input, model = model, stage = stage,
        })
        view.ui().stage = on_stage
        view.update(1)
        view.draw("ctx")
        local shown = false
        for _, c in ipairs(calls) do if c[1] == "DrawList_AddText" and c[6] == "Tom: G" then shown = true end end
        assert.is_true(shown)
      end
    end)

    it("modo Editar não desenha cards nem ações", function()
      local b = ids(draw({ setup = function() view.ui().mode = "edit" end }))
      assert.is_nil(b.act_play)
    end)
  end)
end)
