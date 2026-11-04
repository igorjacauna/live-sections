local stub = require("stubs.reaper")

-- ImGui falsa: o teste escolhe o botão apertado, a opção escolhida num combo,
-- o valor de um slider/campo e o item solto depois da edição.
local function fake_imgui()
  local im = { opts = {}, calls = {}, ids = {} }
  local last, combo = nil, nil
  setmetatable(im, { __index = function(_, name)
    return function(...) im.calls[#im.calls + 1] = { name, ... }; return nil end
  end })
  function im.InvisibleButton(_, id) last = id; im.ids[id] = true; return im.opts.press == id end
  function im.InputText(_, id, v) last = id; if im.opts.value_for == id then return true, im.opts.value end return false, v end
  function im.IsItemHovered() return false end
  function im.CalcTextSize(_, s) return #s * 7, 14 end
  function im.GetWindowDrawList() return "dl" end
  function im.BeginCombo(_, id) combo = id; return im.opts.combo == id end
  function im.Selectable(_, label) return combo == im.opts.combo and label == im.opts.pick end
  function im.SliderDouble(_, id, v) last = id; if im.opts.value_for == id then return true, im.opts.value end return false, v end
  function im.SliderInt(_, id, v) last = id; if im.opts.value_for == id then return true, im.opts.value end return false, v end
  function im.InputInt(_, id, v) last = id; if im.opts.value_for == id then return true, im.opts.value end return false, v end
  function im.Checkbox(_, id, v) last = id; if im.opts.value_for == id then return true, im.opts.value end return false, v end
  function im.IsItemDeactivatedAfterEdit() return im.opts.value_for == last end
  return im
end

describe("ui.settings_view", function()
  local r, im, view, mappings, feedback, layers, perf, learn, dir, ui, library
  local MASTER, KEYS = "SMC-Mixer-Master", "Keys"

  local function frame(opts)
    im.opts = opts or {}
    im.ids = {}
    view.draw("ctx", 0, 0, 1100, 760, {})
  end

  local function config()
    local f = assert(io.open(mappings.config_path(), "r"))
    local data = require("vendor.json").decode(f:read("a"))
    f:close()
    return data
  end

  before_each(function()
    r = stub.install()
    dir = os.tmpname(); os.remove(dir)
    r._resource_path = dir
    for _, m in ipairs({ "core.project_model", "core.quantize", "core.queue", "core.transport", "core.performance",
      "core.layers", "midi.mappings", "midi.learn", "midi.feedback", "ui.theme", "ui.anim", "ui.widgets",
      "ui.performance_view", "ui.settings_view", "core.web_remote", "core.library" }) do
      package.loaded[m] = nil
    end
    r.set_project_length(40)
    r.add_midi_input(4, MASTER)
    r.add_midi_input(5, KEYS)
    r.add_midi_output(4, MASTER)
    mappings, feedback, layers = require("midi.mappings"), require("midi.feedback"), require("core.layers")
    perf, learn = require("core.performance"), require("midi.learn")
    mappings.load()
    library = require("core.library")
    library.init({ mappings = mappings })
    perf.init()
    feedback.configure(mappings.settings())
    im = fake_imgui()
    local theme = require("ui.theme")
    theme.init("ctx", im, "/sem/fontes/")
    local pv = require("ui.performance_view")
    pv.init({ ImGui = im, theme = theme, widgets = require("ui.widgets") })
    ui = pv.ui()
    require("ui.widgets").init(im, theme, require("ui.anim"), learn, mappings)
    view = require("ui.settings_view")
    view.init({
      ImGui = im, theme = theme, kit = pv.kit, mappings = mappings, feedback = feedback, layers = layers,
      perf = perf, anim = require("ui.anim"), learn = learn, model = require("core.project_model"), ui = ui,
      library = library,
    })
    frame()
  end)

  after_each(function() os.execute("rm -rf '" .. dir .. "'") end)

  describe("pasta da biblioteca", function()
    it("mostra a padrão e abre a pasta", function()
      assert.is_true(im.ids.library_open and im.ids.library_choose)
      assert.is_nil(im.ids.library_default)
      frame({ press = "library_open" })
      local calls = r.calls_to("ExecProcess")
      assert.equal('/usr/bin/open "' .. dir .. '/Live Sections/Músicas"', calls[#calls][1])
    end)

    it("Escolher usa a pasta do arquivo escolhido e fica salva; Padrão volta", function()
      os.execute("mkdir -p '" .. dir .. "/Minhas'")
      r._user_file = dir .. "/Minhas/leia-me.txt"
      frame({ press = "library_choose" })
      assert.equal(dir .. "/Minhas", config().settings.library_dir)
      frame()
      assert.is_true(im.ids.library_default)
      frame({ press = "library_default" })
      assert.is_nil(config().settings.library_dir)
      assert.equal(library.default_dir(), (library.dir()))
    end)

    it("escolher o pacote ou um áudio de uma música usa a pasta acima dela", function()
      os.execute("mkdir -p '" .. dir .. "/Minhas/Igreja/audio'")
      r._user_file = dir .. "/Minhas/Igreja/musica.json"
      frame({ press = "library_choose" })
      assert.equal(dir .. "/Minhas", config().settings.library_dir)
      r._files[dir .. "/Minhas/Igreja/musica.json"] = true
      r._user_file = dir .. "/Minhas/Igreja/audio/Guia.wav"
      frame({ press = "library_choose" })
      assert.equal(dir .. "/Minhas", config().settings.library_dir)
    end)

    it("cancelar o diálogo não muda nada", function()
      frame({ press = "library_choose" })
      assert.equal(1, #r.calls_to("GetUserFileNameForRead"))
      assert.is_nil(mappings.settings().library_dir)
    end)

    it("caminho digitado que não existe: avisa e não oferece Abrir pasta", function()
      frame({ value_for = "##library_dir", value = dir .. "/sumiu" })
      assert.equal(dir .. "/sumiu", config().settings.library_dir)
      frame()
      assert.is_nil(im.ids.library_open)
      assert.is_true(im.ids.library_default)
      assert.is_false(select(2, library.dir()))
    end)
  end)

  it("teclado escolhido vai para as camadas e fica salvo", function()
    frame({ combo = "##kbd", pick = KEYS })
    assert.equal(KEYS, layers.keyboard_port())
    assert.equal(KEYS, config().settings.keyboard_port)
  end)

  it("cauda do bypass salva ao soltar o slider, em meios segundos", function()
    frame({ value_for = "##tail", value = 7.3 })
    assert.equal(7.5, config().settings.bypass_tail_s)
  end)

  it("saída dos LEDs: automática por padrão, ou uma saída escolhida", function()
    frame({ combo = "##ledout", pick = MASTER })
    assert.equal(MASTER, config().settings.feedback_out_port)
    frame({ combo = "##ledout", pick = "Automática (mesmo nome da entrada)" })
    assert.is_nil(config().settings.feedback_out_port)
  end)

  it("velocity editada vale na hora e fica salva; Testar acende os LEDs com ela", function()
    mappings.set({ action = "trigger_slot", arg = 1, port_name = MASTER, msg_type = "note", channel = 1, number = 24 })
    feedback.set_state(mappings.get("trigger_slot", 1), "idle")
    frame({ value_for = "##vel_playing", value = 21 })
    assert.equal(21, feedback.velocities().playing)
    assert.equal(21, config().settings.led_velocity.playing)
    r.calls = {}
    frame({ press = "ledtest_playing" })
    feedback.flush(r._now)
    local c = r.calls_to("StuffMIDIMessage")[1]
    assert.same({ 20, 0x90, 24, 21 }, { c[1], c[2], c[3], c[4] })
  end)

  it("tolerância muda na hora, em passos de 5 ms", function()
    frame({ value_for = "##tol", value = 42 })
    assert.equal(40, perf.tolerance_ms())
    assert.equal(40, config().settings.tolerance_ms)
  end)

  it("mapeamento listado pode ser removido; learn global volta para a performance", function()
    mappings.set({ action = "panic", port_name = MASTER, msg_type = "note", channel = 1, number = 5 })
    frame()
    frame({ press = "unmap1" })
    assert.same({}, mappings.all())
    ui.mode = "settings"
    frame({ press = "learn_global" })
    assert.equal("global", learn.state().mode)
    assert.equal("performance", ui.mode)
  end)

  it("as configurações não somem quando um mapeamento é salvo depois", function()
    frame({ combo = "##kbd", pick = KEYS })
    mappings.set({ action = "panic", port_name = MASTER, msg_type = "note", channel = 1, number = 5 })
    mappings.save()
    assert.equal(KEYS, config().settings.keyboard_port)
    package.loaded["midi.mappings"] = nil
    local again = require("midi.mappings")
    again.load()
    assert.equal(KEYS, again.settings().keyboard_port)
  end)

  it("celular: mostra o endereço com QR Code e copia", function()
    os.execute("mkdir -p '" .. dir .. "'")
    local f = io.open(dir .. "/reaper.ini", "w")
    f:write("csurf_0=HTTP 0 8080 '' 'index.html' 0 ''\n")
    f:close()
    r._exec = { ["/sbin/ifconfig"] = "en0: flags=8863\n\tinet 192.168.0.23 netmask 0xffffff00\n" }
    frame({ press = "web_refresh" })
    im.calls = {}
    frame({ press = "copy_url1" })
    local url = "http://192.168.0.23:8080/livesections.html"
    local white, dark, copied = false, 0, nil
    for _, c in ipairs(im.calls) do
      if c[1] == "DrawList_AddRectFilled" and c[7] == 0xFFFFFFFF then white = true end
      if c[1] == "DrawList_AddRectFilled" and c[7] == 0x000000FF then dark = dark + 1 end
      if c[1] == "SetClipboardText" then copied = c[3] end
    end
    assert.is_true(white)
    assert.is_true(dark > 29)
    assert.equal(url, copied)
    local text = {}
    for _, c in ipairs(im.calls) do
      for _, v in ipairs(c) do if type(v) == "string" then text[#text + 1] = v end end
    end
    assert.matches("Chrome → Permissões", table.concat(text, " "))
  end)

  it("rótulos dos controles", function()
    assert.equal("Seção 3", view.label({ action = "trigger_slot", arg = 3 }))
    assert.equal("Panic", view.label({ action = "panic" }))
    assert.equal("Volume da multitrack 2", view.label({ action = "stem_volume", arg = 2 }))
    assert.equal("Liga/desliga a multitrack 5", view.label({ action = "stem_mute", arg = 5 }))
  end)

  it("os controles do Mapeamento não aparecem na lista de mapeamentos", function()
    mappings.set({ action = "kontakt_cc", arg = "k1", port_name = MASTER, msg_type = "cc", channel = 1, number = 16 })
    mappings.set({ action = "panic", port_name = MASTER, msg_type = "note", channel = 1, number = 3 })
    im.calls = {}
    frame()
    local texts = {}
    for _, c in ipairs(im.calls) do if c[1] == "DrawList_AddText" then texts[c[6]] = true end end
    assert.is_true(texts["Panic"])
    assert.is_nil(texts["kontakt_cc"])
    assert.is_nil(texts["CC 16 · canal 1\n" .. MASTER])
  end)
end)
