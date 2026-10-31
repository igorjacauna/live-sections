local stub = require("stubs.reaper")

describe("ui.kontakt_wizard", function()
  local r, model, layers, wizard

  local function song(n) model.refresh(0); return model.songs()[n] end
  local function names() local out = {}; for _, t in ipairs(r._tracks) do out[#out + 1] = t.name end; return out end
  local function depths() local out = {}; for _, t in ipairs(r._tracks) do out[#out + 1] = t.info.I_FOLDERDEPTH or 0 end; return out end
  local function layer_names(s) local out = {}; for _, l in ipairs(layers.layers(s)) do out[#out + 1] = l.name end; return out end
  local function track(name) for _, t in ipairs(r._tracks) do if t.name == name then return t end end end

  before_each(function()
    r = stub.install()
    for _, m in ipairs({ "core.project_model", "core.layers", "ui.kontakt_wizard" }) do package.loaded[m] = nil end
    r.set_project_length(80)
    r.add_marker(0, "SONG: A")
    r.add_marker(40, "SONG: B")
    model, layers, wizard = require("core.project_model"), require("core.layers"), require("ui.kontakt_wizard")
    layers.configure({})
    wizard.init({ layers = layers })
  end)

  it("cria as camadas abaixo do Kontakt, recebendo 1/2 e 3/4; o Kontakt não sai direto", function()
    local k = r.add_track("Kontakt A")
    k.info.B_MAINSEND = 1
    r.add_track("Bateria")
    assert.is_true(wizard.apply(song(1), k, { "Piano", "Pad" }))
    assert.same({ "Kontakt A", "Piano", "Pad", "Bateria" }, names())
    assert.same({ 0, 0, 0, 0 }, depths())
    assert.equal(0, k.info.B_MAINSEND)
    assert.same({ "Piano", "Pad" }, layer_names(song(1)))
    assert.equal(k, layers.track_of(song(1)))
    assert.same({ 0, 2 }, { k.sends[1].info.I_SRCCHAN, k.sends[2].info.I_SRCCHAN })
    assert.equal(track("Pad"), k.sends[2].dst)
    assert.equal(4, k.info.I_NCHAN)
    assert.equal(1, #r.calls_to("Undo_EndBlock"))
  end)

  it("Kontakt em pasta com camadas: desfaz a pasta sem mover tracks e cria a nova depois", function()
    local k = r.add_track("Kontakt A")
    k.info.I_FOLDERDEPTH = 1
    local piano = r.add_track("Piano")
    piano.info.I_FOLDERDEPTH = -1
    r.add_receive(k, piano, 0)
    r.add_track("Bateria")
    wizard.apply(song(1), k, { "Cordas" })
    assert.same({ "Kontakt A", "Piano", "Cordas", "Bateria" }, names())
    assert.same({ 0, 0, 0, 0 }, depths())
    assert.same({ "Piano", "Cordas" }, layer_names(song(1)))
    assert.equal(2, k.sends[2].info.I_SRCCHAN)
  end)

  it("camada antiga só em pasta, sem send: ganha o send do par dela", function()
    local k = r.add_track("Kontakt A")
    k.info.I_FOLDERDEPTH = 1
    r.add_track("Piano").info.I_FOLDERDEPTH = -1
    wizard.apply(song(1), k, {})
    assert.same({ 0, 0 }, depths())
    assert.equal(track("Piano"), k.sends[1].dst)
    assert.same({ "Piano" }, layer_names(song(1)))
  end)

  it("Kontakt dentro de outra pasta: as camadas ficam na mesma pasta", function()
    r.add_track("Banda").info.I_FOLDERDEPTH = 1
    local k = r.add_track("Kontakt A")
    k.info.I_FOLDERDEPTH = -1
    r.add_track("Bateria")
    wizard.apply(song(1), k, { "Piano" })
    assert.same({ "Banda", "Kontakt A", "Piano", "Bateria" }, names())
    assert.same({ 1, 0, -1, 0 }, depths())
    assert.equal(track("Banda"), r.GetParentTrack(track("Piano")))
    assert.is_nil(r.GetParentTrack(track("Bateria")))
  end)

  it("só vincular, sem camadas novas, não mexe nas tracks", function()
    local k = r.add_track("Kontakt A")
    wizard.apply(song(2), k, {})
    assert.same({ "Kontakt A" }, names())
    assert.equal(k, layers.track_of(song(2)))
  end)

  it("com o teclado configurado, a entrada MIDI do Kontakt fica só nele", function()
    r.add_midi_input(5, "Keys")
    layers.configure({ keyboard_port = "Keys" })
    local k = r.add_track("Kontakt A")
    wizard.apply(song(1), k, {})
    assert.equal(4096 + (5 << 5), k.info.I_RECINPUT)
  end)

  it("candidatos marcam as tracks com Kontakt", function()
    r.add_track("Bateria")
    r.add_track("Teclas").fx = { "VSTi: Kontakt 7 (Native Instruments)" }
    local c = wizard.candidates()
    assert.same({ false, true }, { c[1].kontakt, c[2].kontakt })
    assert.equal("2. Teclas", c[2].name)
  end)
end)
