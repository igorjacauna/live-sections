local stub = require("stubs.reaper")

describe("library", function()
  local r, lib, mappings, dir, src

  local function write_file(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
  end

  local function pkg(name, extra)
    local p = {
      format = 1, name = name, exported_at = "2026-11-03 10:00", length = 60,
      bpm = 120, signature = "4/4", phase_beats = 0,
      tempo = { { t = 0, bpm = 120, num = 4, denom = 4 } },
      regions = { { start = 0, ["end"] = 8, name = "Intro" }, { start = 8, ["end"] = 30, name = "Verso" } },
      tracks = { { name = "Guia", level = 0, chunk = '<TRACK\nFILE "audio/Guia.wav"\n>' } },
      audio = { { file = "audio/Guia.wav", from = src .. "/Guia.wav" } },
      plugins = {}, params = {}, mapping_rows = {},
    }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
  end

  before_each(function()
    r = stub.install()
    dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "/src'")
    src = dir .. "/src"
    r._resource_path = dir .. "/res"
    write_file(src .. "/Guia.wav", string.rep("A", 3 * 1024 * 1024 + 7))
    for _, m in ipairs({ "midi.mappings", "core.library" }) do package.loaded[m] = nil end
    mappings = require("midi.mappings")
    mappings.load()
    lib = require("core.library")
    lib.init({ mappings = mappings })
  end)

  after_each(function() os.execute("rm -rf '" .. dir .. "'") end)

  describe("pasta", function()
    it("padrão nos recursos do REAPER, criada na hora", function()
      local path, ok = lib.dir()
      assert.equal(dir .. "/res/Live Sections/Músicas", path)
      assert.is_true(ok)
    end)

    it("escolhida fica nas configurações; ausente avisa; nil volta à padrão", function()
      lib.set_dir(src)
      assert.same({ src, true }, { lib.dir() })
      assert.equal(src, mappings.settings().library_dir)
      lib.set_dir(dir .. "/sumiu")
      assert.same({ dir .. "/sumiu", false }, { lib.dir() })
      lib.set_dir(nil)
      assert.equal(lib.default_dir(), (lib.dir()))
    end)

    it("nome de pasta válido no Windows", function()
      assert.equal("AC_DC _ Live_", lib.folder_name(' AC/DC | Live? '))
      assert.equal("Música", lib.folder_name("..."))
    end)
  end)

  describe("gravar e ler", function()
    it("grava o pacote e copia o áudio inteiro", function()
      local ok, err, info = lib.write(pkg("Igreja"))
      assert.is_true(ok, err)
      assert.equal(lib.default_dir() .. "/Igreja", info.path)
      assert.same({ 1, 3 * 1024 * 1024 + 7 }, { info.copied, info.bytes })
      assert.equal(read_file(src .. "/Guia.wav"), read_file(info.path .. "/audio/Guia.wav"))
      assert.is_true(lib.exists("Igreja"))
      assert.is_false(lib.exists("Outra"))
    end)

    it("lê de volta com o caminho absoluto dos áudios", function()
      lib.write(pkg("Igreja"))
      local p = lib.read("Igreja")
      assert.equal("Igreja", p.name)
      assert.equal(lib.default_dir() .. "/Igreja", p.folder)
      assert.equal(p.folder .. "/audio/Guia.wav", p.audio[1].path)
      assert.equal('<TRACK\nFILE "audio/Guia.wav"\n>', p.tracks[1].chunk)
    end)

    it("áudio que sumiu antes de copiar fica marcado", function()
      local p = pkg("Igreja")
      p.audio[1].from = src .. "/nao-existe.wav"
      local ok, _, info = lib.write(p)
      assert.is_true(ok)
      assert.equal(0, info.copied)
      assert.is_true(lib.read("Igreja").audio[1].missing)
    end)

    it("substituir tira os áudios que não voltam", function()
      write_file(src .. "/Velho.wav", "x")
      lib.write(pkg("Igreja", { audio = { { file = "audio/Velho.wav", from = src .. "/Velho.wav" } } }))
      local folder = lib.default_dir() .. "/Igreja"
      assert.is_not_nil(read_file(folder .. "/audio/Velho.wav"))
      lib.write(pkg("Igreja"))
      assert.is_nil(read_file(folder .. "/audio/Velho.wav"))
      assert.is_not_nil(read_file(folder .. "/audio/Guia.wav"))
    end)

    it("reexportar uma música que já usa o áudio da biblioteca não o apaga", function()
      lib.write(pkg("Igreja"))
      local inside = lib.default_dir() .. "/Igreja/audio/Guia.wav"
      local before = read_file(inside)
      assert.is_true((lib.write(pkg("Igreja", { audio = { { file = "audio/Guia.wav", from = inside } } }))))
      assert.equal(before, read_file(inside))
    end)

    it("sem a pasta escolhida não grava e diz onde", function()
      lib.set_dir(dir .. "/sumiu")
      local ok, err, info = lib.write(pkg("Igreja"))
      assert.is_false(ok)
      assert.equal("no_dir", err)
      assert.equal(dir .. "/sumiu", info.path)
    end)

    it("sem permissão de escrita: erro com o caminho", function()
      lib.set_dir(src)
      os.execute("mkdir -p '" .. src .. "/Igreja/audio' && chmod 555 '" .. src .. "/Igreja' '" .. src .. "/Igreja/audio'")
      local ok, err, info = lib.write(pkg("Igreja"))
      os.execute("chmod -R 755 '" .. src .. "/Igreja'")
      assert.is_false(ok)
      assert.equal("no_write", err)
      assert.equal(src .. "/Igreja/audio/Guia.wav", info.path)
    end)
  end)

  describe("lista", function()
    it("resumo por nome; JSON ilegível ou de outro formato não abre", function()
      lib.write(pkg("Igreja", { bpm = 129, signature = "6/8",
        tempo = { { t = 0, bpm = 120, num = 4, denom = 4 }, { t = 30, bpm = 60, num = 3, denom = 4 } } }))
      lib.write(pkg("Amazing Grace"))
      local base = lib.default_dir()
      os.execute("mkdir -p '" .. base .. "/Quebrada' '" .. base .. "/Futura' '" .. base .. "/Vazia'")
      write_file(base .. "/Quebrada/musica.json", "{ nada")
      write_file(base .. "/Futura/musica.json", '{"format": 2, "tracks": []}')
      local list = lib.list()
      local names = {}
      for i, s in ipairs(list) do names[i] = s.name end
      assert.same({ "Amazing Grace", "Futura", "Igreja", "Quebrada" }, names)
      assert.same({ 129, "6/8", 25, 2, "2026-11-03 10:00", true },
        { list[3].bpm, list[3].signature, list[3].bars, list[3].sections, list[3].exported_at, list[3].ok })
      assert.same({ false, "unknown_format" }, { list[2].ok, list[2].err })
      assert.same({ false, "unreadable" }, { list[4].ok, list[4].err })
      assert.same({ nil, "unreadable" }, { lib.read("Quebrada") })
    end)

    it("pasta escolhida ausente: lista vazia", function()
      lib.set_dir(dir .. "/sumiu")
      assert.same({}, lib.list())
    end)
  end)

  describe("plugins e pasta", function()
    it("lista os plugins que faltam, sem contar o JSFX do Live Sections", function()
      r._installed_fx = {
        { "VSTi: Kontakt 7 (Native Instruments)", "Kontakt.vst3" },
        { "JS: Volume Adjustment", "utility/volume" },
      }
      local p = pkg("Igreja", { plugins = {
        "VSTi: Kontakt 7 (Native Instruments)", "JS: utility/volume",
        "VST3: ValhallaRoom (Valhalla DSP)", "JS: LiveSections/ls_kontakt_cc.jsfx",
      } })
      assert.same({ "VST3: ValhallaRoom (Valhalla DSP)" }, lib.missing_plugins(p))
    end)

    it("abre a pasta no Explorer ou no Finder", function()
      lib.open_folder("/x/Músicas")
      assert.equal('/usr/bin/open "/x/Músicas"', r.calls_to("ExecProcess")[1][1])
      r._app_version = "7.84/win64"
      lib.open_folder("C:\\x")
      assert.equal('explorer "C:\\x"', r.calls_to("ExecProcess")[2][1])
    end)
  end)
end)
