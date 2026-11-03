local stub = require("stubs.reaper")

describe("core.chart", function()
  local r, chart

  local TEXT = table.concat({
    "Tom: G",
    "",
    "[Intro]",
    "| G | D | Em | C |",
    "",
    "[Verso]",
    "G              D",
    "  Quando a noite chegar",
    "Em             C",
    "  eu vou te encontrar",
    "Ela disse que sim",
    "",
    "[Refrão]",
    "C   G   D",
    "  Ô ô ô",
  }, "\n")

  before_each(function()
    r = stub.install()
    package.loaded["core.chart"] = nil
    chart = require("core.chart")
  end)

  describe("parse", function()
    it("separa introdução e blocos; agrupa acordes com a letra de baixo", function()
      local p = chart.parse(TEXT)
      assert.same({ "Tom: G" }, p.intro)
      assert.same({ "Intro", "Verso", "Refrão" }, { p.blocks[1].name, p.blocks[2].name, p.blocks[3].name })
      local verso = p.blocks[2].units
      assert.equal(3, #verso)
      assert.same({ "pair", "pair", "lyrics" }, { verso[1].kind, verso[2].kind, verso[3].kind })
      assert.equal("  Quando a noite chegar", verso[1].lines[2])
    end)

    it("linha em grade: uma célula por compasso", function()
      local u = chart.parse(TEXT).blocks[1].units[1]
      assert.equal("grid", u.kind)
      assert.same({ "G", "D", "Em", "C" }, u.cells)
      assert.equal(4, u.bars)
      local two = chart.parse("[A]\n| G D | Am7(9)/G | F#m7b5 |").blocks[1].units[1]
      assert.same({ "G D", "Am7(9)/G", "F#m7b5" }, two.cells)
    end)

    it("palavras não viram acordes; acordes variados sim", function()
      local p = chart.parse("[X]\nBb7M  C7(9)  D/F#  Gº  Asus4  Cmaj7\nEla\nA casa caiu")
      local u = p.blocks[1].units
      assert.equal("pair", u[1].kind)
      assert.equal("lyrics", u[2].kind)
    end)

    it("acorde entre parênteses e anotação com acordes de sobra continuam acordes", function()
      local p = chart.parse("[X]\n   ( C ) C7M\nDigno\n Dm7(11)  C/E  F2 Riff\nSobre\nEm Deus\nA casa e a rua")
      local u = p.blocks[1].units
      assert.same({ "pair", "pair", "lyrics", "lyrics" }, { u[1].kind, u[2].kind, u[3].kind, u[4].kind })
    end)
  end)

  describe("units_for", function()
    it("casa pelo nome, sem acento nem caixa; 'Refrão 2' usa o 2º [Refrão] ou o 1º", function()
      local p = chart.parse("[Refrao]\nC\n[Refrão]\nD\n[verso]\nG")
      assert.equal("C", chart.units_for(p, { name = "Refrão" })[1].lines[1])
      assert.equal("D", chart.units_for(p, { name = "Refrão 2" })[1].lines[1])
      assert.equal("C", chart.units_for(p, { name = "Refrão 3" })[1].lines[1])
      assert.equal("G", chart.units_for(p, { name = "Verso 2" })[1].lines[1])
      assert.is_nil(chart.units_for(p, { name = "Ponte" }))
    end)
  end)

  describe("view", function()
    local verso
    before_each(function() verso = chart.parse(TEXT).blocks[2].units end)

    it("teleprompter: a seção inteira, o verso atual, os que passaram e o ponto de leitura", function()
      -- Verso: 3 versos em 6 compassos = 2 compassos cada; 5 linhas
      local rows, focus = chart.view(verso, 0.5, 6, 6)
      assert.equal(5, #rows)
      assert.is_true(rows[1].current and rows[2].current)
      assert.is_nil(rows[3].current)
      assert.near(0.5, focus, 1e-9)                 -- 1/4 do 1º verso (2 linhas)
      rows, focus = chart.view(verso, 2.1, 6, 6)
      assert.is_true(rows[1].past and rows[2].past)
      assert.is_true(rows[3].current)
      assert.near(2.1, focus, 1e-9)
      rows, focus = chart.view(verso, 5, 6, 6)
      assert.is_true(rows[5].current)
      assert.near(4.5, focus, 1e-9)
    end)

    it("'A seguir' com até max_lines linhas da próxima", function()
      local refrao = chart.parse(TEXT).blocks[3].units
      local rows = chart.view(verso, 0, 6, 8, "Refrão", refrao)
      assert.same({ "next", "Refrão" }, { rows[6].kind, rows[6].text })
      assert.equal("C   G   D", rows[7].text)
    end)

    it("{N} no fim da linha diz quantos compassos o verso dura; o resto divide o que sobra", function()
      local units = chart.parse("[A]\nG\nletra um {1}\nD\nletra dois\nE  {1,5}\nletra três").blocks[1].units
      assert.equal("letra um", units[1].lines[2])
      assert.equal("E", units[3].lines[1])
      assert.same({ 1, nil, 1.5 }, { units[1].bars, units[2].bars, units[3].bars })
      -- 5 compassos: 1 + 2,5 + 1,5
      local rows = chart.view(units, 1.2, 5, 6)
      assert.is_true(rows[3].current)
      rows = chart.view(units, 3.6, 5, 6)
      assert.is_true(rows[5].current)
    end)

    it("grade: o compasso atual acende a célula; versos comuns dividem o que sobra", function()
      local units = chart.parse("[A]\n| G | D |\nC\nletra").blocks[1].units
      -- 6 compassos: grade 2 + verso comum 4
      local rows = chart.view(units, 1.5, 6, 6)
      assert.equal("grid", rows[1].kind)
      assert.equal(2, rows[1].cell)
      rows = chart.view(units, 2, 6, 6)
      assert.equal("grid", rows[1].kind)
      assert.is_nil(rows[1].cell)                 -- a grade já passou
    end)
  end)

  describe("projeto", function()
    it("guarda o texto por música, com quebras de linha e barras", function()
      r.add_marker(0, "SONG: A")
      local model = require("core.project_model")
      model.refresh(0)
      local song = model.songs()[1]
      assert.equal("", chart.get_text(song))
      assert.is_true(chart.set_text(song, "[A]\nG \\ D\n"))
      assert.equal("[A]\nG \\ D\n", chart.get_text(song))
      for _, v in pairs(r._ext.LiveSections) do assert.is_nil(v:find("\n", 1, true)) end
      assert.equal("A", chart.for_song(song).blocks[1].name)
    end)
  end)
end)
