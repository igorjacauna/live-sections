local stub = require("stubs.reaper")

-- 4/4 a 120 BPM: compasso = 2 s. Música A: Intro 0–8 (4 comp.), Verso 8–16 (4 comp.).
describe("core.stage", function()
  local r, stage, chart, model, json

  local CHART = "[Intro]\n| G | D | Em | C |\n[Verso]\nG       D\nQuando a noite\nEm      C\neu vou te achar"

  local function snap(pos, extra)
    model.refresh(0)
    local song, section = model.song_at(pos)
    local s = { song = song, section = section, pos = pos, playing = true }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
  end

  before_each(function()
    r = stub.install()
    for _, m in ipairs({ "core.project_model", "core.chart", "core.song_notes", "core.stage" }) do package.loaded[m] = nil end
    r.add_marker(0, "SONG: A")
    r.add_region(0, 8, "Intro", 0x1000000 | 0xEF8D5B)
    r.add_region(8, 16, "Verso")
    r.set_project_length(16)
    model, chart, stage = require("core.project_model"), require("core.chart"), require("core.stage")
    json = require("vendor.json")
    model.refresh(0)
    chart.set_text(model.songs()[1], CHART)
  end)

  it("música, seção com cor, compasso e próxima seção", function()
    local s = stage.build(snap(3))
    assert.same({ "A", "Intro", "Verso", 2, 4 }, { s.song, s.section, s.next, s.bar, s.bars })
    assert.equal("#5B8DEF", s.color)
    assert.is_true(s.has_chart)
  end)

  it("grade da Intro acende o compasso atual", function()
    local s = stage.build(snap(5))
    assert.equal("grid", s.rows[1].kind)
    assert.equal(3, s.rows[1].cell)
  end)

  it("Verso: a seção inteira com o verso atual e o ponto de leitura; progresso de 0 a 1", function()
    local s = stage.build(snap(13), { max_lines = 2 })
    assert.equal(4, #s.rows)
    assert.is_true(s.rows[3].current)
    assert.is_true(s.rows[1].past)
    assert.near(2.5, s.focus, 1e-3)               -- metade do 2º verso
    assert.equal(0.625, s.progress)               -- 2,5 de 4 compassos
    assert.equal(0, stage.build(snap(8)).progress)
  end)

  it("fila: mostra a seção da fila com as batidas restantes", function()
    local verso = model.songs()[1].sections[2]
    local s = stage.build(snap(3, { queued_section = verso, beats_left = 3 }))
    assert.same({ "Verso", true, 3 }, { s.next, s.queued, s.beats_left })
  end)

  it("leva a anotação da música", function()
    assert.is_nil(stage.build(snap(3)).note)
    require("core.song_notes").set(model.songs()[1], "Tom: G")
    assert.equal("Tom: G", stage.build(snap(3)).note)
  end)

  it("música sem cifra: sem linhas e has_chart falso", function()
    chart.set_text(model.songs()[1], "")
    local s = stage.build(snap(3))
    assert.is_nil(s.rows)
    assert.is_false(s.has_chart)
  end)

  it("publica no ExtState só quando muda, no máximo a cada 0,1 s", function()
    local s = stage.build(snap(3))
    assert.is_true(stage.publish(s, 1))
    assert.is_false(stage.publish(s, 2))
    local moved = stage.build(snap(5))
    assert.is_false(stage.publish(moved, 1.05))
    assert.is_true(stage.publish(moved, 1.2))
    assert.equal("Intro", json.decode(r._gext.LiveSections.stage).section)
    stage.shutdown()
    assert.is_false(json.decode(r._gext.LiveSections.stage).open)
  end)
end)
