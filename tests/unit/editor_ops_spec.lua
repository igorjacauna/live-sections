local stub = require("stubs.reaper")

-- 4/4 a 120 BPM: compasso = 2 s.
-- Música A (0–40): Intro 0–8, Verso 8–16, Refrão 16–24, sem seção 24–28, Outro 28–40.
-- Música B (40–64): Intro 40–48, Verso 48–64.
describe("editor_ops", function()
  local r, model, ops

  local function song(n) model.refresh(0); return model.songs()[n] end
  local function sec(n, name)
    for _, s in ipairs(song(n).sections) do if s.name == name then return s end end
    error("seção não encontrada: " .. name)
  end

  -- Nenhuma sobreposição e todo início/fim de região no compasso.
  local function assert_clean()
    local rg = r.regions()
    for i, x in ipairs(rg) do
      assert.near(0, x[1] % 2, 1e-9, "início fora do compasso: " .. x[3])
      assert.near(0, x[2] % 2, 1e-9, "fim fora do compasso: " .. x[3])
      assert.is_true(x[2] > x[1], "seção vazia: " .. x[3])
      if rg[i + 1] then assert.is_true(x[2] <= rg[i + 1][1] + 1e-9, "sobreposição: " .. x[3] .. " e " .. rg[i + 1][3]) end
    end
  end

  local function undo_blocks()
    return #r.calls_to("Undo_BeginBlock"), #r.calls_to("Undo_EndBlock")
  end

  before_each(function()
    r = stub.install()
    package.loaded["core.project_model"] = nil
    package.loaded["core.editor_ops"] = nil
    model = require("core.project_model")
    ops = require("core.editor_ops")
    r.set_project_length(64)
    r.add_marker(0, "SONG: A")
    r.add_region(0, 8, "Intro", 0x1000001)
    r.add_region(8, 16, "Verso", 0x1000002)
    r.add_region(16, 24, "Refrão", 0x1000003)
    r.add_region(28, 40, "Outro", 0x1000004)
    r.add_marker(40, "SONG: B")
    r.add_region(40, 48, "Intro")
    r.add_region(48, 64, "Verso")
    r.calls = {}
  end)

  describe("split", function()
    it("divide no compasso mais próximo; a segunda parte herda cor e ganha nome numerado", function()
      assert.is_true(ops.split(song(1), 11.3))   -- compasso mais próximo: 12 s
      assert.same({ 8, 12, "Verso" }, r.regions()[2])
      assert.same({ 12, 16, "Verso 2" }, r.regions()[3])
      assert.equal(0x1000002, sec(1, "Verso 2").color)
      assert.same({ 1, 1 }, { undo_blocks() })
      assert_clean()
    end)

    it("dividir no limite de uma seção retorna erro sem efeito", function()
      local ok, err = ops.split(song(1), 16.4)
      assert.is_false(ok)
      assert.equal("boundary", err)
      assert.equal(0, #r.calls)
    end)

    it("dividir num trecho sem seção retorna erro sem efeito", function()
      local ok, err = ops.split(song(1), 25.0)
      assert.same({ false, "no_section" }, { ok, err })
      assert.equal(0, #r.calls)
    end)
  end)

  describe("merge_next", function()
    it("junta com a próxima e apaga a região dela", function()
      assert.is_true(ops.merge_next(song(1), sec(1, "Verso")))
      assert.same({ 8, 24, "Verso" }, r.regions()[2])
      assert.equal(5, #r.regions())   -- eram 6
      assert.same({ 1, 1 }, { undo_blocks() })
    end)

    it("absorve o trecho sem seção entre as duas", function()
      ops.merge_next(song(1), sec(1, "Refrão"))
      assert.same({ 16, 40, "Refrão" }, r.regions()[3])
      assert_clean()
    end)

    it("sem próxima seção na música retorna erro", function()
      local ok, err = ops.merge_next(song(1), sec(1, "Outro"))
      assert.same({ false, "no_next" }, { ok, err })
    end)
  end)

  describe("resize", function()
    it("mover a borda entre duas seções move as duas juntas, com snap", function()
      assert.is_true(ops.resize(song(1), sec(1, "Verso"), "end", 13.1))
      assert.same({ 8, 14, "Verso" }, r.regions()[2])
      assert.same({ 14, 24, "Refrão" }, r.regions()[3])
      assert.same({ 1, 1 }, { undo_blocks() })
      assert_clean()
    end)

    it("a borda de início também puxa a anterior", function()
      ops.resize(song(1), sec(1, "Verso"), "start", 4.2)
      assert.same({ 0, 4, "Intro" }, r.regions()[1])
      assert.same({ 4, 16, "Verso" }, r.regions()[2])
    end)

    it("a vizinha fica com pelo menos um compasso", function()
      ops.resize(song(1), sec(1, "Verso"), "end", 30)
      assert.same({ 8, 22, "Verso" }, r.regions()[2])
      assert.same({ 22, 24, "Refrão" }, r.regions()[3])
    end)

    it("com trecho sem seção ao lado, a borda anda sozinha até a próxima seção", function()
      ops.resize(song(1), sec(1, "Refrão"), "end", 35)
      assert.same({ 16, 28, "Refrão" }, r.regions()[3])
      assert.same({ 28, 40, "Outro" }, r.regions()[4])
    end)

    it("a seção não fica com menos de um compasso", function()
      ops.resize(song(1), sec(1, "Verso"), "end", 7)
      assert.same({ 8, 10, "Verso" }, r.regions()[2])
    end)

    it("sem mudança não cria passo de undo", function()
      ops.resize(song(1), sec(1, "Verso"), "end", 16.3)
      assert.same({ 0, 0 }, { undo_blocks() })
    end)

    it("set_length muda a duração em compassos", function()
      assert.is_true(ops.set_length(song(1), sec(1, "Intro"), 2))
      assert.same({ 0, 4, "Intro" }, r.regions()[1])
      assert.same({ 4, 16, "Verso" }, r.regions()[2])
      assert.same({ false, "too_short" }, { ops.set_length(song(1), sec(1, "Intro"), 0) })
    end)
  end)

  describe("rename", function()
    it("numera nomes repetidos na mesma música", function()
      local ok, name = ops.rename(song(1), sec(1, "Outro"), "Verso")
      assert.same({ true, "Verso 2" }, { ok, name })
      ok, name = ops.rename(song(1), sec(1, "Intro"), "Verso")
      assert.equal("Verso 3", name)
    end)

    it("o mesmo nome em outra música não conta", function()
      local _, name = ops.rename(song(2), sec(2, "Intro"), "Refrão")
      assert.equal("Refrão", name)
    end)

    it("manter o próprio nome não numera", function()
      local _, name = ops.rename(song(1), sec(1, "Verso"), "Verso")
      assert.equal("Verso", name)
    end)

    it("aplica a cor do chip quando informada", function()
      ops.rename(song(1), sec(1, "Outro"), "Ponte", 0x1009B6B)
      assert.equal(0x1009B6B, sec(1, "Ponte").color)
    end)
  end)

  describe("create_song", function()
    it("cria o marcador SONG: e uma seção até a próxima música", function()
      r.set_project_length(100)
      assert.is_true(ops.create_song(model.songs(), 70.6, "Maré Alta"))
      model.refresh(0)
      local c = model.songs()[3]
      assert.same({ "Maré Alta", 70, 100 }, { c.name, c.start_pos, c.end_pos })
      assert.same({ 70, 100, "Seção" }, r.regions()[#r.regions()])
      assert.same({ 1, 1 }, { undo_blocks() })
      assert_clean()
    end)

    it("num trecho sem seção, a seção inicial vai até a próxima seção", function()
      model.refresh(0)
      assert.is_true(ops.create_song(model.songs(), 24.4, "Interlúdio"))
      assert.same({ 24, 28, "Seção" }, r.regions()[4])
      assert_clean()
    end)

    it("no meio de uma seção retorna erro sem efeito", function()
      model.refresh(0)
      local ok, err = ops.create_song(model.songs(), 11, "X")
      assert.same({ false, "inside_section" }, { ok, err })
      assert.equal(0, #r.calls)
    end)

    it("no início de uma seção cria só o marcador", function()
      model.refresh(0)
      assert.is_true(ops.create_song(model.songs(), 28.2, "Outro lado"))
      assert.equal(1, #r.calls_to("AddProjectMarker2"))
      model.refresh(0)
      assert.equal("Outro lado", model.songs()[2].name)
    end)
  end)

  describe("draw", function()
    it("desenhar no meio de uma seção a divide em duas", function()
      local ok, name = ops.draw(song(2), 51.7, 56.2)       -- compassos 52–56 dentro de Verso 48–64
      assert.same({ true, "Seção" }, { ok, name })
      local rg = r.regions()
      assert.same({ 48, 52, "Verso" }, rg[6])
      assert.same({ 52, 56, "Seção" }, rg[7])
      assert.same({ 56, 64, "Verso 2" }, rg[8])
      assert.same({ 1, 1 }, { undo_blocks() })
      assert_clean()
    end)

    it("desenhar sobre uma borda recorta a vizinha", function()
      ops.draw(song(1), 6, 12, "Pré")
      local rg = r.regions()
      assert.same({ 0, 6, "Intro" }, rg[1])
      assert.same({ 6, 12, "Pré" }, rg[2])
      assert.same({ 12, 16, "Verso" }, rg[3])
      assert_clean()
    end)

    it("desenhar sobre várias seções remove as cobertas, num passo de undo", function()
      ops.draw(song(1), 7.9, 30.1, "Ponte")                 -- 8–30: cobre Verso e Refrão, recorta Outro
      local rg = r.regions()
      assert.same({ 0, 8, "Intro" }, rg[1])
      assert.same({ 8, 30, "Ponte" }, rg[2])
      assert.same({ 30, 40, "Outro" }, rg[3])
      assert.equal(2, #r.calls_to("DeleteProjectMarker"))
      assert.same({ 1, 1 }, { undo_blocks() })
      assert_clean()
    end)

    it("arrastar da direita para a esquerda dá o mesmo resultado", function()
      ops.draw(song(1), 28, 24, "Solo")
      assert.same({ 24, 28, "Solo" }, r.regions()[4])
    end)

    it("um clique sem arrastar cria uma seção de um compasso", function()
      ops.draw(song(1), 25, 25.1)
      assert.same({ 24, 26, "Seção" }, r.regions()[4])
      assert_clean()
    end)

    it("não passa dos limites da música", function()
      ops.draw(song(1), 36, 50, "Final")
      assert.same({ 36, 40, "Final" }, r.regions()[5])
      assert.same({ 40, 48, "Intro" }, r.regions()[6])
    end)

    it("nome repetido ganha numeração", function()
      local _, name = ops.draw(song(1), 24, 28, "Verso")
      assert.equal("Verso 2", name)
    end)

    it("buracos que sobram ficam sem seção e sem slot", function()
      ops.draw(song(1), 2, 4, "Pré")
      ops.draw(song(1), 2, 4, "Pré")                         -- redesenha no mesmo lugar
      ops.draw(song(1), 10, 12, "Pré")
      local a = song(1)
      local slots = {}
      for _, s in ipairs(a.sections) do slots[#slots + 1] = s.slot end
      assert.same({ 1, 2, 3, 4, 5, 6, 7, 8 }, slots)
      assert.same({ { start_pos = 24, end_pos = 28 } }, a.gaps)

      ops.merge_next(song(1), sec(1, "Pré"))                 -- Pré 2–4 + Intro 2 4–8 = 2–8
      ops.split(song(1), 6)
      assert_clean()
    end)
  end)
end)
