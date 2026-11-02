local stub = require("stubs.reaper")

describe("layers", function()
  local r, model, layers
  local KEYS = "Keystation 61"
  local songs, a, b, c, kt_a, kt_b

  local function key(status, d1, d2) return { port_name = KEYS, status = status, data1 = d1, data2 = d2 } end
  local function info(tr, k) return tr.info[k] or 0 end
  local function armed(tr) return info(tr, "I_RECARM") == 1 and info(tr, "I_RECMON") == 1 end

  before_each(function()
    r = stub.install()
    package.loaded["core.project_model"] = nil
    package.loaded["core.layers"] = nil
    model = require("core.project_model")
    layers = require("core.layers")
    r.set_project_length(120)
    r.add_marker(0, "SONG: A")
    r.add_marker(40, "SONG: B")
    r.add_marker(80, "SONG: C")
    r.add_midi_input(2, "SMC-Mixer-Master")
    r.add_midi_input(5, KEYS)
    kt_a = r.add_track("Kontakt A", "{KT-A}")
    r.add_track("Cordas", "{A-1}", kt_a)
    r.add_track("Piano", "{A-2}", kt_a)
    r.add_track("Bateria", "{DR}")
    kt_b = r.add_track("Kontakt B", "{KT-B}")
    kt_a.info.I_FXEN, kt_b.info.I_FXEN = 1, 1
    model.refresh(0)
    songs = model.songs()
    a, b, c = songs[1], songs[2], songs[3]
    layers.configure({ keyboard_port = KEYS, bypass_tail_s = 5 })
    layers.link(a, kt_a)
    layers.link(b, kt_b)
  end)

  describe("vínculo e camadas", function()
    it("guarda o GUID da track pelo GUID do marcador da música", function()
      assert.equal(kt_a, layers.track_of(a))
      assert.is_nil(layers.track_of(c))
      local links = layers.links(songs)
      assert.equal("{KT-B}", links[b.id].track_guid)
      assert.matches("^kontakt:{MK%-M%-", links[b.id].key)
      assert.is_nil(links[c.id])
    end)

    it("o vínculo segue a música quando o marcador muda de posição", function()
      reaper.SetProjectMarker3(0, b.marker_idx, false, 44, 0, "SONG: B", 0)
      model.refresh(0)
      assert.equal(kt_b, layers.track_of(model.songs()[2]))
    end)

    it("camadas são as tracks filhas diretas, em ordem", function()
      local list = layers.layers(a)
      assert.same({ { "Cordas", 1, "{A-1}" }, { "Piano", 2, "{A-2}" } },
        { { list[1].name, list[1].slot, list[1].track_guid }, { list[2].name, list[2].slot, list[2].track_guid } })
      assert.same({}, layers.layers(c))
    end)

    it("unlink desfaz o vínculo; track apagada não é encontrada", function()
      layers.unlink(a)
      assert.is_nil(layers.track_of(a))
      table.remove(r._tracks, #r._tracks)     -- Kontakt B
      assert.is_nil(layers.track_of(b))
    end)
  end)

  describe("activate", function()
    it("arma e monitora só a track da música atual, com entrada no teclado", function()
      assert.is_true(layers.activate(a, songs, 0))
      assert.is_true(armed(kt_a))
      assert.equal(4096 + (5 << 5), info(kt_a, "I_RECINPUT"))
      assert.is_false(armed(kt_b))

      layers.activate(b, songs, 10)
      assert.is_true(armed(kt_b))
      assert.is_false(armed(kt_a))
    end)

    it("música sem vínculo não roteia nada e desarma a anterior", function()
      layers.activate(a, songs, 0)
      assert.is_true(layers.activate(c, songs, 10))
      assert.is_false(armed(kt_a))
      assert.is_false(armed(kt_b))
    end)

    it("sem teclado configurado não arma (nunca All MIDI inputs)", function()
      layers.configure({ keyboard_port = "Teclado ausente" })
      assert.same({ false, "no_keyboard" }, { layers.activate(a, songs, 0) })
      assert.is_false(armed(kt_a))
      assert.equal(0, info(kt_a, "I_RECINPUT"))
    end)

    it("com nota segurada a track anterior fica armada até o Note Off", function()
      layers.activate(a, songs, 0)
      layers.feed(key(0x90, 60, 100))
      layers.activate(b, songs, 10)
      assert.is_true(armed(kt_a))
      assert.is_true(armed(kt_b))
      layers.tick(10.5)
      assert.is_true(armed(kt_a))
      layers.feed(key(0x80, 60, 0))
      layers.tick(11)
      assert.is_false(armed(kt_a))
    end)

    it("o sustain também segura a track anterior; Note On com velocity 0 solta a nota", function()
      layers.activate(a, songs, 0)
      layers.feed(key(0x90, 60, 100))
      layers.feed(key(0xB0, 64, 127))
      layers.feed(key(0x90, 60, 0))
      layers.activate(b, songs, 10)
      layers.tick(11)
      assert.is_true(armed(kt_a))
      layers.feed(key(0xB0, 64, 0))
      layers.tick(12)
      assert.is_false(armed(kt_a))
    end)

    it("notas de outras portas não contam", function()
      layers.activate(a, songs, 0)
      layers.feed({ port_name = "SMC-Mixer-Master", status = 0x90, data1 = 24, data2 = 127 })
      assert.is_false(layers.held())
      layers.activate(b, songs, 10)
      assert.is_false(armed(kt_a))
    end)

    it("voltar para a música enquanto a anterior espera o teclado mantém ela armada", function()
      layers.activate(a, songs, 0)
      layers.feed(key(0x90, 60, 100))
      layers.activate(b, songs, 10)
      layers.activate(a, songs, 11)
      layers.feed(key(0x80, 60, 0))
      layers.tick(12)
      assert.is_true(armed(kt_a))
      assert.is_false(armed(kt_b))
    end)
  end)

  describe("bypass", function()
    it("os Kontakts das outras músicas entram em bypass depois da cauda", function()
      layers.activate(a, songs, 0)
      layers.tick(4.9)
      assert.equal(1, info(kt_b, "I_FXEN"))
      layers.tick(5)
      assert.equal(0, info(kt_b, "I_FXEN"))
      assert.equal(1, info(kt_a, "I_FXEN"))
    end)

    it("ao trocar, a música anterior sai do bypass na hora e a que saiu espera a cauda", function()
      layers.activate(a, songs, 0)
      layers.tick(6)
      layers.activate(b, songs, 20)
      assert.equal(1, info(kt_b, "I_FXEN"))
      layers.tick(24)
      assert.equal(1, info(kt_a, "I_FXEN"))
      layers.tick(25)
      assert.equal(0, info(kt_a, "I_FXEN"))
    end)

    it("voltar antes do fim da cauda cancela o bypass", function()
      layers.activate(a, songs, 0)
      layers.activate(b, songs, 10)
      layers.activate(a, songs, 12)
      layers.tick(20)
      assert.equal(1, info(kt_a, "I_FXEN"))
    end)

    it("track removida durante a cauda é ignorada", function()
      layers.activate(a, songs, 0)
      table.remove(r._tracks, #r._tracks)
      assert.has_no.errors(function() layers.tick(10) end)
    end)
  end)

  describe("faders de camada", function()
    local cordas, piano, pad_b
    local function pos(tr) return reaper.DB2SLIDER(20 * math.log(tr.info.D_VOL, 10)) / 1000 end

    before_each(function()
      cordas, piano = r._tracks[2], r._tracks[3]
      pad_b = r.add_track("Pad", "{B-1}", kt_b)
      cordas.info.D_VOL, piano.info.D_VOL, pad_b.info.D_VOL = 1, 1, 0.5   -- 0 dB, 0 dB, ≈ -6 dB
      layers.activate(a, songs, 0)
    end)

    it("o fader N muda o volume nativo da camada N da música atual, depois de alcançá-la", function()
      assert.equal("waiting", layers.set_layer_volume(1, 0.2))      -- 0 dB fica em 0,716
      assert.equal("set", layers.set_layer_volume(1, 0.72))          -- cruzou
      assert.near(0.72, pos(cordas), 1e-9)
      assert.equal("set", layers.set_layer_volume(1, 0.3))
      assert.near(0.3, pos(cordas), 1e-9)
      assert.equal(1, piano.info.D_VOL)
    end)

    it("renomeia a camada N da música atual, num passo de undo", function()
      assert.same({ true, "Violinos" }, { layers.rename_layer(1, "  Violinos ") })
      assert.equal("Violinos", cordas.name)
      assert.equal("Live Sections: renomear camada", r.calls_to("Undo_EndBlock")[1][1])
      assert.same({ false, "empty_name" }, { layers.rename_layer(2, "  ") })
      assert.same({ false, "no_layer" }, { layers.rename_layer(5, "X") })
      assert.equal("Piano", piano.name)
    end)

    it("fader perto do valor atual já assume", function()
      assert.equal("set", layers.set_layer_volume(2, 0.70))
    end)

    it("no zero, a camada fica muda", function()
      layers.set_layer_volume(1, 0.716)
      layers.set_layer_volume(1, 0)
      assert.equal(0, cordas.info.D_VOL)
    end)

    it("depois de trocar de música, o fader espera cruzar o valor da nova camada", function()
      layers.set_layer_volume(1, 0.716)
      layers.set_layer_volume(1, 0.9)
      layers.activate(b, songs, 10)                                 -- Pad em ≈ 0,506
      assert.equal("down", layers.takeover(1))
      assert.equal("waiting", layers.set_layer_volume(1, 0.8))
      assert.equal(0.5, pad_b.info.D_VOL)
      assert.equal("set", layers.set_layer_volume(1, 0.45))         -- passou por 0,506
      assert.is_nil(layers.takeover(1))
      assert.near(0.45, pos(pad_b), 1e-9)
    end)

    it("informa a direção para alcançar: acima ou abaixo", function()
      layers.set_layer_volume(1, 0.1)
      assert.equal("up", layers.takeover(1))
      assert.is_nil(layers.takeover(2))           -- fader 2 ainda não se mexeu
    end)

    it("reativar a mesma música não perde o controle do fader", function()
      layers.set_layer_volume(1, 0.716)
      layers.activate(a, songs, 5)
      assert.equal("set", layers.set_layer_volume(1, 0.2))
    end)

    it("release_takeover faz o fader alcançar de novo (volume mudou pela tela)", function()
      layers.set_layer_volume(1, 0.716)
      cordas.info.D_VOL = 0.1                                       -- ≈ 0,226
      layers.release_takeover()
      assert.equal("waiting", layers.set_layer_volume(1, 0.5))
      assert.equal("set", layers.set_layer_volume(1, 0.2))
    end)

    it("camada inexistente ou música sem Kontakt não faz nada", function()
      assert.equal("no_layer", layers.set_layer_volume(3, 0.5))
      layers.activate(c, songs, 10)
      assert.equal("no_layer", layers.set_layer_volume(1, 0.5))
      assert.is_false(layers.toggle_mute(1))
    end)

    it("layer_state mostra posição, mute e solo; o fader da tela solta o físico", function()
      layers.set_layer_volume(1, 0.716)
      layers.toggle_mute(1)
      local st = layers.layer_state(1)
      assert.same({ "Cordas", true, false }, { st.name, st.mute, st.solo })
      assert.near(0.716, st.pos, 1e-9)
      assert.is_nil(layers.layer_state(3))

      assert.is_true(layers.set_volume_ui(1, 0.3))
      assert.near(0.3, pos(cordas), 1e-9)
      assert.equal("waiting", layers.set_layer_volume(1, 0.6))     -- não cruzou 0,3
    end)

    it("mute e solo por camada alternam na track da camada", function()
      assert.is_true(layers.toggle_mute(2))
      assert.equal(1, piano.info.B_MUTE)
      layers.toggle_mute(2)
      assert.equal(0, piano.info.B_MUTE)
      layers.toggle_solo(1)
      assert.equal(2, cordas.info.I_SOLO)
      layers.toggle_solo(1)
      assert.equal(0, cordas.info.I_SOLO)
    end)
  end)
end)
