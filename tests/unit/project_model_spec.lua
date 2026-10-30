local stub = require("stubs.reaper")

describe("project_model", function()
  local r, model

  before_each(function()
    r = stub.install()
    package.loaded["core.project_model"] = nil
    model = require("core.project_model")
  end)

  local function names(list)
    local out = {}
    for _, x in ipairs(list) do out[#out + 1] = x.name end
    return out
  end

  describe("músicas", function()
    it("vão de um marcador SONG: até o próximo e a última até o fim do projeto", function()
      r.set_project_length(100)
      r.add_marker(0, "SONG: Rua Augusta")
      r.add_marker(40, "SONG:Maré Alta  ")
      r.add_marker(20, "Ponte (marcador comum)")

      model.refresh(0)
      local songs = model.songs()

      assert.same({ "Rua Augusta", "Maré Alta" }, names(songs))
      assert.same({ 0, 40 }, { songs[1].start_pos, songs[1].end_pos })
      assert.same({ 40, 100 }, { songs[2].start_pos, songs[2].end_pos })
      assert.is_number(songs[1].marker_idx)
    end)

    it("sem marcador SONG:, o projeto inteiro é uma música", function()
      r.set_project_length(30)
      r.add_region(0, 8, "Intro")
      r.add_region(8, 32, "Verso")

      model.refresh(0)
      local songs = model.songs()

      assert.equal(1, #songs)
      assert.same({ 0, 32 }, { songs[1].start_pos, songs[1].end_pos })
      assert.same({ "Intro", "Verso" }, names(songs[1].sections))
    end)

    it("o fim do projeto considera a última região mesmo sem itens", function()
      r.add_marker(0, "SONG: A")
      r.add_region(0, 16, "Intro")

      model.refresh(0)

      assert.equal(16, model.songs()[1].end_pos)
    end)
  end)

  describe("seções", function()
    before_each(function()
      r.set_project_length(64)
      r.add_marker(0, "SONG: A")
      r.add_marker(32, "SONG: B")
      r.add_region(8, 16, "Verso", 0x10FF0000)
      r.add_region(0, 8, "Intro", 0x100000FF)
      r.add_region(20, 32, "Refrão")
      r.add_region(32, 48, "Intro")
    end)

    it("herdam nome, cor e ordem da região e ganham slot 1..N por música", function()
      model.refresh(0)
      local a, b = model.songs()[1], model.songs()[2]

      assert.same({ "Intro", "Verso", "Refrão" }, names(a.sections))
      assert.same({ 1, 2, 3 }, { a.sections[1].slot, a.sections[2].slot, a.sections[3].slot })
      assert.equal(0x100000FF, a.sections[1].color)
      assert.same({ 8, 16 }, { a.sections[2].start_pos, a.sections[2].end_pos })
      assert.is_number(a.sections[2].region_idx)

      assert.same({ "Intro" }, names(b.sections))
      assert.equal(1, b.sections[1].slot)
    end)

    it("trechos sem seção aparecem em gaps, sem slot", function()
      model.refresh(0)
      local a, b = model.songs()[1], model.songs()[2]

      assert.same({ { start_pos = 16, end_pos = 20 } }, a.gaps)
      assert.same({ { start_pos = 48, end_pos = 64 } }, b.gaps)
    end)

    it("song_at devolve a música e a seção, ou nil num trecho sem seção", function()
      model.refresh(0)

      local song, sec = model.song_at(10)
      assert.same({ "A", "Verso" }, { song.name, sec.name })

      song, sec = model.song_at(17)
      assert.equal("A", song.name)
      assert.is_nil(sec)

      song, sec = model.song_at(32)
      assert.same({ "B", "Intro" }, { song.name, sec.name })

      assert.is_nil(model.song_at(64))
    end)
  end)

  describe("refresh", function()
    it("só relê quando o contador de mudanças do projeto muda", function()
      r.add_marker(0, "SONG: A")
      r.add_region(0, 8, "Intro")

      assert.is_true(model.refresh(0))
      assert.is_false(model.refresh(0))

      r._markers[2].name = "Abertura" -- edição feita no REAPER
      assert.is_false(model.refresh(0))
      assert.equal("Intro", model.songs()[1].sections[1].name)

      r.touch()
      assert.is_true(model.refresh(0))
      assert.equal("Abertura", model.songs()[1].sections[1].name)
    end)

    it("não lê os marcadores quando nada mudou", function()
      r.add_region(0, 8, "Intro")
      local enum, reads = r.EnumProjectMarkers3, 0
      r.EnumProjectMarkers3 = function(...) reads = reads + 1; return enum(...) end

      model.refresh(0)
      local first = reads
      model.refresh(0)
      model.refresh(0)

      assert.is_true(first > 0)
      assert.equal(first, reads)
    end)
  end)
end)
