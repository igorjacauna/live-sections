local stub = require("stubs.reaper")

-- ImGui falsa: o teste escolhe o botão apertado, a opção do combo, o valor
-- de um campo e o item solto depois da edição; os textos desenhados ficam
-- em `texts`.
local function fake_imgui()
  local im = { opts = {}, calls = {}, texts = {} }
  local last, combo = nil, nil
  setmetatable(im, { __index = function(_, name)
    return function(...) im.calls[#im.calls + 1] = { name, ... }; return nil end
  end })
  function im.InvisibleButton(_, id) last = id; return im.opts.press == id end
  function im.IsItemHovered() return false end
  function im.CalcTextSize(_, s) return #s * 7, 14 end
  function im.GetWindowDrawList() return "dl" end
  function im.DrawList_AddText(_, _, _, _, s) im.texts[#im.texts + 1] = s end
  function im.BeginCombo(_, id) combo = id; return im.opts.combo == id end
  function im.Selectable(_, label) return combo == im.opts.combo and label == im.opts.pick end
  function im.InputInt(_, id, v) last = id; if im.opts.value_for == id then return true, im.opts.value end return false, v end
  function im.InputText(_, id, v) last = id; if im.opts.value_for == id then return true, im.opts.value end return false, v end
  function im.IsItemDeactivatedAfterEdit() return im.opts.value_for == last end
  return im
end

describe("ui.mapping_view", function()
  local r, im, view, mappings, learn, feedback, kcc, dir, ui, jsfx, songs
  local fake_layers = { track_of = function(song) return song.track end }
  local fake_model = { songs = function() return songs end }
  local SMC = "SMC-Mixer-bt"

  local function ev(status, d1, d2) return { port_name = SMC, status = status, data1 = d1, data2 = d2 } end

  local function frame(opts)
    im.opts = opts or {}
    im.texts = {}
    view.draw("ctx", 0, 0, 1100, 760, {})
  end

  local function drawn(pattern)
    for _, t in ipairs(im.texts) do
      if t:find(pattern, 1, true) then return true end
    end
    return false
  end

  local function init(status)
    view.init({
      ImGui = im, theme = require("ui.theme"), kit = require("ui.performance_view").kit, kontakt_cc = kcc,
      learn = learn, feedback = feedback, ui = ui, label = require("ui.settings_view").label, jsfx_status = status,
      jsfx = jsfx, layers = fake_layers, model = fake_model,
    })
  end

  before_each(function()
    r = stub.install()
    dir = os.tmpname(); os.remove(dir)
    r._resource_path = dir
    for _, m in ipairs({ "midi.mappings", "midi.learn", "midi.feedback", "ui.theme", "ui.anim", "ui.widgets",
      "ui.performance_view", "ui.settings_view", "ui.mapping_view", "core.kontakt_cc", "core.kontakt_jsfx" }) do
      package.loaded[m] = nil
    end
    mappings, learn, feedback = require("midi.mappings"), require("midi.learn"), require("midi.feedback")
    mappings.load()
    songs = {}
    jsfx = require("core.kontakt_jsfx")
    kcc = require("core.kontakt_cc")
    kcc.init({ mappings = mappings, jsfx = jsfx, layers = fake_layers })
    im = fake_imgui()
    local theme = require("ui.theme")
    theme.init("ctx", im, "/sem/fontes/")
    local pv = require("ui.performance_view")
    pv.init({ ImGui = im, theme = theme, widgets = require("ui.widgets") })
    ui = pv.ui()
    view = require("ui.mapping_view")
    init()
    frame()
  end)

  after_each(function() os.execute("rm -rf '" .. dir .. "'") end)

  it("sem linhas, explica como começar", function()
    assert.is_true(drawn("Nenhum controle ainda"))
  end)

  it("Aprender vários cria uma linha por controle mexido e para no segundo clique", function()
    frame({ press = "kcc_series" })
    assert.equal("series", learn.state().mode)
    learn.feed(ev(0xB0, 16, 40))
    learn.feed(ev(0x90, 0, 127))
    frame()
    assert.is_true(drawn("Knob CC16") and drawn("Botão C-2"))
    assert.is_true(drawn("Mexa os controles"))
    frame({ press = "kcc_series" })
    assert.is_nil(learn.state())
    assert.equal(2, #kcc.rows())
  end)

  describe("com linhas", function()
    before_each(function()
      kcc.add_from_learn({ port_name = SMC, msg_type = "cc", channel = 1, number = 16 })
      kcc.add_from_learn({ port_name = SMC, msg_type = "note", channel = 1, number = 0 })
      frame()
    end)

    it("mostra nome, controle físico e porta", function()
      assert.is_true(drawn("Knob CC16") and drawn(SMC))
      assert.is_true(drawn("NOME") and drawn("CONTROLE") and drawn("TIPO"))
    end)

    it("edita o nome ao terminar de digitar", function()
      frame({ value_for = "##kname_k1", value = "Cutoff" })
      assert.equal("Cutoff", kcc.get("k1").name)
    end)

    it("edita o CC, limitado a 0–127", function()
      frame({ value_for = "##kcc_k1", value = 63 })
      assert.equal(63, kcc.get("k1").cc)
      frame({ value_for = "##kcc_k1", value = 300 })
      assert.equal(127, kcc.get("k1").cc)
    end)

    it("muda o tipo pelo combo", function()
      frame({ combo = "##kkind_k2", pick = "Segurar" })
      assert.equal("momentary", kcc.get("k2").kind)
    end)

    it("Reaprender liga o learn da linha e clicar de novo cancela", function()
      frame({ press = "krelearn_k1" })
      assert.same({ "kontakt_cc", "k1" }, { learn.state().control.action, learn.state().control.arg })
      frame()
      assert.is_true(drawn("Mexa o controle"))
      frame({ press = "krelearn_k1" })
      assert.is_nil(learn.state())
    end)

    it("Remover tira a linha e o controle", function()
      frame({ press = "kdel_k1" })
      assert.is_nil(kcc.get("k1"))
      assert.is_nil(kcc.mapping("k1"))
    end)

    it("avisa CC repetido e reservado", function()
      kcc.update("k2", { cc = kcc.get("k1").cc })
      frame()
      assert.is_true(drawn('CC repetido com "Botão C-2"'))
      kcc.update("k2", { cc = 64 })
      frame()
      assert.is_true(drawn("CC que o Kontakt já usa"))
    end)

    it("avisa linha que perdeu o controle físico", function()
      mappings.set({ action = "next_song", port_name = SMC, msg_type = "cc", channel = 1, number = 16 })
      frame()
      assert.is_true(drawn("Sem controle"))
      assert.is_true(drawn("Reaprenda"))
    end)
  end)

  it("mostra o conflito do learn com o nome da ação", function()
    ui.learn_conflict = { mapping = { action = "layer_mute", arg = 1 }, at = reaper.time_precise() }
    frame()
    assert.is_true(drawn('Esse controle já é "Mute da camada 1"'))
  end)

  it("mostra o erro ao gravar o JSFX com o caminho", function()
    init({ ok = false, err = "Permission denied", path = "C:/REAPER/Effects/LiveSections/ls_kontakt_cc.jsfx" })
    frame()
    assert.is_true(drawn("C:/REAPER/Effects/LiveSections/ls_kontakt_cc.jsfx"))
    assert.is_true(drawn("Permission denied"))
  end)

  describe("segurança", function()
    local kt_a, kt_b

    local function kontakt(name)
      local t = r.add_track(name)
      t.fx = { "VST3i: Kontakt 8" }
      return t
    end

    before_each(function()
      kt_a, kt_b = kontakt("A"), kontakt("B")
      songs = { { name = "A", track = kt_a }, { name = "B", track = kt_b }, { name = "Sem Kontakt" } }
      jsfx.install(kt_a)
      kcc.add_from_learn({ port_name = SMC, msg_type = "cc", channel = 1, number = 16 })
      kcc.on_song(songs[1])
      init()
      frame()
    end)

    it("conta as músicas com o JSFX e instala nas que faltam", function()
      assert.is_true(drawn("JSFX instalado em 1 de 2 músicas com Kontakt"))
      frame({ press = "kcc_install_all" })
      assert.equal(0, jsfx.find(kt_b))
      frame()
      assert.is_true(drawn("JSFX instalado em 2 de 2 músicas com Kontakt"))
    end)

    it("sem música com Kontakt, explica", function()
      songs = { { name = "Sem Kontakt" } }
      init()
      frame()
      assert.is_true(drawn("Nenhuma música deste projeto tem Kontakt vinculado"))
    end)

    it("Testar e Enviar p/ Learn mandam o CC da linha ao Kontakt atual", function()
      local cc = kcc.get("k1").cc
      frame({ press = "klearn_k1" })
      assert.equal(127, jsfx.value(kt_a, cc))
      kcc.tick(reaper.time_precise() + 5)
      frame({ press = "ktest_k1" })
      assert.equal(0, jsfx.value(kt_a, cc))
    end)

    it("a barra mostra o valor e a luz acende quando o CC sai", function()
      kcc.handle(kcc.mapping("k1"), 1, nil, reaper.time_precise())
      local function circles()
        local out = {}
        for _, c in ipairs(im.calls) do
          if c[1] == "DrawList_AddCircleFilled" and c[5] == 5 then out[#out + 1] = c[6] end
        end
        return out
      end
      im.calls = {}
      frame()
      local theme = require("ui.theme")
      assert.same({ theme.C.raise2 }, circles())
      reaper.TrackFX_SetParam(kt_a, 0, 129, 1)
      kcc.tick(reaper.time_precise())
      im.calls = {}
      frame()
      assert.same({ theme.C.ok }, circles())
      assert.is_true(drawn("SINAL"))
    end)
  end)
end)
