local stub = require("stubs.reaper")

describe("layer_params", function()
  local r, model, layers, lp, a, b, kt_a, kt_b
  local rows, values, touched

  local fake_kcc = {
    get = function(id) return rows[id] end,
    value = function(id) return values[id] end,
    touched = function(id, now) return touched[id] == now end,
  }

  local function names(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v.name end
    return out
  end

  before_each(function()
    r = stub.install()
    package.loaded["core.project_model"] = nil
    package.loaded["core.layers"] = nil
    package.loaded["core.layer_params"] = nil
    model = require("core.project_model")
    layers = require("core.layers")
    lp = require("core.layer_params")
    r.set_project_length(120)
    r.add_marker(0, "SONG: A")
    r.add_marker(40, "SONG: B")
    kt_a = r.add_track("Kontakt A", "{KT-A}")
    r.add_track("Piano", "{A-1}", kt_a)
    r.add_track("Orgão", "{A-2}", kt_a)
    kt_b = r.add_track("Kontakt B", "{KT-B}")
    r.add_track("Synth", "{B-1}", kt_b)
    model.refresh(0)
    a, b = model.songs()[1], model.songs()[2]
    layers.link(a, kt_a)
    layers.link(b, kt_b)
    rows, values, touched = {}, {}, {}
    for i, kind in ipairs({ "knob", "toggle", "momentary", "encoder", "knob", "knob" }) do
      rows["k" .. i] = { id = "k" .. i, name = "Linha " .. i, cc = 20 + i, kind = kind }
    end
    lp.init({ layers = layers, kontakt_cc = fake_kcc })
  end)

  it("liga linhas às camadas e mostra cada uma na sua, na ordem", function()
    assert.is_true(lp.bind(a, 1, "k1"))
    assert.is_true(lp.bind(a, 2, "k2"))
    assert.is_true(lp.bind(a, 1, "k5"))
    assert.same({ "Linha 1", "Linha 5" }, names(lp.for_layer(a, 1, 0)))
    assert.same({ "Linha 2" }, names(lp.for_layer(a, 2, 0)))
    assert.equal(2, lp.count(a, 1))
  end)

  it("é por música e pelo GUID da track", function()
    lp.bind(a, 1, "k1")
    lp.bind(b, 1, "k1")
    lp.rename(b, "k1", "Cutoff")
    assert.same({ "Linha 1" }, names(lp.for_layer(a, 1, 0)))
    assert.same({ "Cutoff" }, names(lp.for_layer(b, 1, 0)))
    local saved = r._ext.LiveSections["params:" .. layers.song_key(a)]
    assert.matches('"layer":"{A%-1}"', saved)
  end)

  it("ligar a outra camada move e mantém o nome", function()
    lp.bind(a, 1, "k1")
    lp.rename(a, "k1", "Reverb")
    assert.is_true(lp.bind(a, 2, "k1"))
    assert.same({}, lp.for_layer(a, 1, 0))
    assert.same({ "Reverb" }, names(lp.for_layer(a, 2, 0)))
    assert.is_true(lp.move(a, "k1", 1))
    assert.same({ "Reverb" }, names(lp.for_layer(a, 1, 0)))
  end)

  it("no máximo 4 por camada: ligar ou mover para uma camada cheia é recusado", function()
    for i = 1, 4 do assert.is_true(lp.bind(a, 1, "k" .. i)) end
    assert.same({ false, "full" }, { lp.bind(a, 1, "k5") })
    lp.bind(a, 2, "k5")
    assert.same({ false, "full" }, { lp.move(a, "k5", 1) })
    assert.same({ "Linha 5" }, names(lp.for_layer(a, 2, 0)))
    assert.is_true(lp.bind(a, 1, "k1"))          -- já está lá: nada muda
  end)

  it("recusa camada ou linha inexistente e mover o que não é parâmetro", function()
    assert.same({ false, "no_layer" }, { lp.bind(a, 3, "k1") })
    assert.same({ false, "no_row" }, { lp.bind(a, 1, "k99") })
    assert.same({ false, "not_param" }, { lp.move(a, "k1", 2) })
    assert.same({ false, "not_param" }, { lp.remove(a, "k1") })
  end)

  it("renomear com nome vazio volta ao nome da linha; remover tira da camada", function()
    lp.bind(a, 1, "k1")
    lp.rename(a, "k1", "  Reverb  ")
    assert.same({ "Reverb" }, names(lp.for_layer(a, 1, 0)))
    lp.rename(a, "k1", "  ")
    assert.same({ "Linha 1" }, names(lp.for_layer(a, 1, 0)))
    assert.is_true(lp.remove(a, "k1"))
    assert.same({}, lp.list(a))
    assert.is_nil(r._ext.LiveSections["params:" .. layers.song_key(a)])
  end)

  it("cada mudança é um passo de undo", function()
    lp.bind(a, 1, "k1")
    lp.rename(a, "k1", "Reverb")
    lp.remove(a, "k1")
    assert.same({ "Live Sections: parâmetro da camada", "Live Sections: parâmetro da camada",
      "Live Sections: parâmetro da camada" }, r._undo)
  end)

  it("linha removida do Mapeamento some e é limpa na próxima gravação", function()
    lp.bind(a, 1, "k1")
    lp.bind(a, 1, "k2")
    rows.k1 = nil
    assert.same({ "Linha 2" }, names(lp.for_layer(a, 1, 0)))
    lp.rename(a, "k2", "Rotary")
    assert.is_nil(r._ext.LiveSections["params:" .. layers.song_key(a)]:find('"k1"'))
  end)

  it("camada que não recebe mais do Kontakt não mostra o parâmetro", function()
    lp.bind(a, 2, "k1")
    r._ext.LiveSections["params:" .. layers.song_key(a)] = '[{"row":"k1","layer":"{SUMIU}","name":""}]'
    assert.same({}, lp.for_layer(a, 1, 0))
    assert.same({}, lp.for_layer(a, 2, 0))
    assert.is_false(lp.is_param(a, "k1"))
  end)

  it("JSON ilegível vira lista vazia", function()
    reaper.SetProjExtState(0, "LiveSections", "params:" .. layers.song_key(a), "{ quebrado")
    assert.same({}, lp.list(a))
    assert.same({}, lp.for_layer(a, 1, 0))
  end)

  it("mostra valor, ON/OFF, segurar e pisca; valor desconhecido fica nil", function()
    for i = 1, 4 do lp.bind(a, 1, "k" .. i) end
    values.k1, values.k2, values.k3 = 64, 127, 0
    touched.k1 = 5
    local v = lp.for_layer(a, 1, 5)
    assert.same({ "knob", 64, true }, { v[1].kind, v[1].value, v[1].flash })
    assert.same({ true, false }, { v[2].on, v[2].flash })
    assert.is_false(v[3].held)
    assert.is_nil(v[4].value)
    values.k3 = 127
    assert.is_true(lp.for_layer(a, 1, 5)[3].held)
    values.k2 = 0
    assert.is_false(lp.for_layer(a, 1, 5)[2].on)
  end)

  it("is_param só vale para parâmetros da música", function()
    lp.bind(a, 1, "k1")
    assert.is_true(lp.is_param(a, "k1"))
    assert.is_false(lp.is_param(a, "k2"))
    assert.is_false(lp.is_param(b, "k1"))
  end)
end)
