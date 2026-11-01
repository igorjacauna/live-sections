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

    it("mostra a seção inteira, sem linha atual, quando cabe", function()
      -- Verso: 2 versos de acordes + letra e 1 só de letra = 5 linhas
      for _, bar in ipairs({ 0.5, 2.1, 5 }) do
        local rows = chart.view(verso, bar, 6, 6)
        assert.equal(5, #rows)
        assert.equal("chords", rows[1].kind)
        assert.equal("Ela disse que sim", rows[5].text)
        for _, row in ipairs(rows) do assert.is_nil(row.current) end
      end
    end)

    it("se não cabe, rola com a seção sem cortar um verso", function()
      -- 6 compassos, 3 versos: 2 compassos cada; 3 linhas na tela
      local rows = chart.view(verso, 0.5, 6, 3)
      assert.equal(2, #rows)                      -- o 2º verso não cabe inteiro
      assert.equal(verso[1].lines[1], rows[1].text)
      rows = chart.view(verso, 2.1, 6, 3)
      assert.equal(verso[2].lines[1], rows[1].text)
      assert.equal(3, #rows)
      -- no último verso, o anterior volta para preencher a tela
      rows = chart.view(verso, 5, 6, 3)
      assert.equal(verso[2].lines[1], rows[1].text)
      assert.equal("Ela disse que sim", rows[3].text)
    end)

    it("seção inteira na tela e espaço sobrando: 'A seguir' com o começo da próxima", function()
      local refrao = chart.parse(TEXT).blocks[3].units
      local rows = chart.view(verso, 0, 6, 8, "Refrão", refrao)
      assert.same({ "next", "Refrão" }, { rows[6].kind, rows[6].text })
      assert.equal("C   G   D", rows[7].text)
      assert.is_nil(chart.view(verso, 0, 6, 5, "Refrão", refrao)[6])
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
