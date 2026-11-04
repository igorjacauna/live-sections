local stub = require("stubs.reaper")

-- Música A (0–40) e B (40–80). Tracks: Kontakt A com a camada Piano;
-- Bateria, Baixo e Click com itens em A; Vozes com item só em B.
describe("stems", function()
  local r, model, layers, stems, a, b
  local kt, piano, bateria, baixo, click, vozes

  local function names(list)
    local out = {}
    for i, tr in ipairs(list) do out[i] = tr.name end
    return out
  end

  local function pos(tr) return reaper.DB2SLIDER(20 * math.log(tr.info.D_VOL, 10)) / 1000 end

  before_each(function()
    r = stub.install()
    for _, m in ipairs({ "core.project_model", "core.layers", "core.stems" }) do package.loaded[m] = nil end
    model, layers, stems = require("core.project_model"), require("core.layers"), require("core.stems")
    r.set_project_length(80)
    r.add_marker(0, "SONG: A")
    r.add_marker(40, "SONG: B")
    kt = r.add_track("Kontakt A", "{KT}")
    piano = r.add_track("Piano", "{PIANO}")
    r.add_receive(kt, piano, 0)
    bateria = r.add_track("Bateria", "{BAT}")
    baixo = r.add_track("Baixo", "{BX}")
    click = r.add_track("Click", "{CLK}")
    vozes = r.add_track("Vozes", "{VOZ}")
    for _, tr in ipairs({ bateria, baixo, click, piano }) do r.add_item(2, 30, -1, tr) end
    r.add_item(41, 30, -1, vozes)
    for _, tr in ipairs(r._tracks) do tr.info.D_VOL = 1 end
    model.refresh(0)
    a, b = model.songs()[1], model.songs()[2]
    layers.link(a, kt)
    stems.init({ layers = layers })
  end)

  describe("escolha", function()
    it("candidatos: tracks com item na música, sem o Kontakt nem as camadas", function()
      assert.same({ "Bateria", "Baixo", "Click" }, names((function()
        local out = {}
        for _, c in ipairs(stems.candidates(a)) do out[#out + 1] = c.track end
        return out
      end)()))
      assert.same({ "Vozes" }, { stems.candidates(b)[1].name })
    end)

    it("fica salva por música, na ordem do projeto, num passo de undo sem plugins", function()
      assert.is_true(stems.toggle(a, baixo))
      assert.is_true(stems.toggle(a, bateria))
      assert.same({ "Bateria", "Baixo" }, names(stems.list(a)))
      assert.same({}, stems.list(b))
      local ends = r.calls_to("Undo_EndBlock")
      assert.same({ "Live Sections: multitracks da música", 8 }, { ends[1][1], ends[1][2] })
      assert.is_true(stems.candidates(a)[1].on)
      stems.toggle(a, baixo)
      assert.same({ "Bateria" }, names(stems.list(a)))
    end)

    it("até 8 por música", function()
      local many = {}
      for i = 1, 9 do many[i] = r.add_track("T" .. i, "{T" .. i .. "}") end
      assert.same({ false, "full" }, { stems.set(a, many) })
      table.remove(many)
      assert.is_true(stems.set(a, many))
      assert.same({ false, "full" }, { stems.toggle(a, bateria) })
    end)

    it("track apagada ou que virou camada sai da lista; JSON ilegível vira vazio", function()
      stems.set(a, { bateria, baixo, click })
      table.remove(r._tracks, 5)                   -- apaga o Click
      r.add_receive(kt, baixo, 2)                  -- Baixo vira camada
      r._state_count = r._state_count + 1
      assert.same({ "Bateria" }, names(stems.list(a)))
      reaper.SetProjExtState(0, "LiveSections", "stems:" .. layers.song_key(a), "{ nada")
      assert.same({}, stems.list(a))
    end)

    it("escolhida sem itens na música continua nos candidatos para desmarcar", function()
      stems.set(a, { vozes })
      local c = stems.candidates(a)
      assert.same({ "Bateria", "Baixo", "Click", "Vozes" }, { c[1].name, c[2].name, c[3].name, c[4].name })
      assert.is_true(c[4].on)
    end)
  end)

  describe("ao vivo", function()
    before_each(function()
      stems.set(a, { bateria, baixo })
      stems.activate(a)
    end)

    it("fader com soft takeover: só assume ao cruzar o volume da track", function()
      assert.equal(2, stems.count())
      assert.equal("waiting", stems.set_volume(1, 0.2))
      assert.equal("up", stems.takeover(1))
      assert.equal("set", stems.set_volume(1, 0.9))           -- cruzou 0,716 (0 dB)
      assert.near(0.9, pos(bateria), 1e-9)
      assert.is_nil(stems.takeover(1))
      assert.equal("set", stems.set_volume(1, 0.5))
      assert.near(0.5, pos(bateria), 1e-9)
    end)

    it("trocar de música recomeça o takeover; slot sem multitrack é ignorado", function()
      stems.set_volume(1, 0.716)
      stems.activate(b)
      assert.equal("no_stem", stems.set_volume(1, 0.5))
      assert.is_false(stems.toggle_mute(1))
      stems.activate(a)
      assert.equal("waiting", stems.set_volume(1, 0.2))
      assert.equal("no_stem", stems.set_volume(3, 0.5))
    end)

    it("fader da tela solta o físico; mute; renomear; estado com cor", function()
      assert.is_true(stems.set_volume_ui(2, 0.3))
      assert.near(0.3, pos(baixo), 1e-9)
      assert.equal("waiting", stems.set_volume(2, 0.6))
      assert.is_true(stems.toggle_mute(2))
      baixo.info.I_CUSTOMCOLOR = 0x1000000 | 0x112233
      local st = stems.state(2)
      assert.same({ "Baixo", true, 0x112233 }, { st.name, st.mute, st.color })
      assert.near(0.3, st.pos, 1e-9)
      assert.same({ true, "Contrabaixo" }, { stems.rename(2, "  Contrabaixo ") })
      assert.equal("Contrabaixo", baixo.name)
      assert.same({ false, "empty_name" }, { stems.rename(2, " ") })
      assert.same({ false, "no_stem" }, { stems.rename(5, "X") })
      assert.is_nil(stems.state(3))
    end)
  end)
end)
