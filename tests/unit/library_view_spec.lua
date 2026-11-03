local stub = require("stubs.reaper")

describe("ui.library_view", function()
  local r, lv, dir, song, guia, bateria, kt, built, written, existing, write_result

  local fake_pkg = {
    detect_tracks = function() return { guia, kt } end,
    build = function(s, tracks, opts)
      built = { song = s, tracks = tracks, name = opts.name }
      return { name = opts.name }, { missing_audio = { "/proj/Click.wav" } }
    end,
  }
  local fake_lib = {
    exists = function(name) return existing[name] == true end,
    write = function(pkg) written = pkg; return table.unpack(write_result) end,
    dir = function() return "/lib", true end,
    open_folder = function() end,
  }

  local function write_file(path, n)
    local f = assert(io.open(path, "wb"))
    f:write(string.rep("x", n))
    f:close()
  end

  before_each(function()
    r = stub.install()
    package.loaded["ui.library_view"] = nil
    lv = require("ui.library_view")
    lv.init({ library = fake_lib, song_package = fake_pkg })
    dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "'")
    write_file(dir .. "/guia.wav", 3 * 1024 * 1024)
    write_file(dir .. "/bat.wav", 1024)
    guia = r.add_track("Guia")
    bateria = r.add_track("Bateria")
    kt = r.add_track("Kontakt")
    r.add_item(4, 10, -1, guia).file = dir .. "/guia.wav"
    r.add_item(20, 10, -1, guia).file = dir .. "/guia.wav"
    r.add_item(50, 10, -1, guia).file = dir .. "/outra.wav"
    r.add_item(8, 10, -1, bateria).file = dir .. "/bat.wav"
    song = { name = "Igreja", start_pos = 0, end_pos = 40 }
    built, written, existing = nil, nil, {}
    write_result = { true, nil, { path = "/lib/Igreja", copied = 1, bytes = 3 * 1024 * 1024 } }
  end)

  after_each(function() os.execute("rm -rf '" .. dir .. "'") end)

  it("lista todas as tracks, com as detectadas marcadas, itens e tamanho", function()
    lv.open_export(song)
    local s = lv.export_state()
    assert.equal("Igreja", s.name)
    assert.same({ "1. Guia", "2. Bateria", "3. Kontakt" }, { s.tracks[1].label, s.tracks[2].label, s.tracks[3].label })
    assert.same({ true, false, true }, { s.tracks[1].on, s.tracks[2].on, s.tracks[3].on })
    assert.same({ 2, 3 * 1024 * 1024 }, { s.items, s.bytes })
    assert.equal("3.0 MB", lv.size_text(s.bytes))
  end)

  it("marcar outra track soma os itens dela", function()
    lv.open_export(song)
    lv.toggle(2)
    assert.same({ 3, 3 * 1024 * 1024 + 1024 }, { lv.export_state().items, lv.export_state().bytes })
    lv.toggle(1)
    assert.same({ 1, 1024 }, { lv.export_state().items, lv.export_state().bytes })
  end)

  it("exporta as tracks marcadas com o nome escolhido e mostra o resultado", function()
    lv.open_export(song)
    lv.set_name("  Igreja (ao vivo) ")
    local res = lv.export()
    assert.equal("done", res)
    assert.same({ guia, kt }, built.tracks)
    assert.equal("Igreja (ao vivo)", built.name)
    local text = lv.export_state().result.text
    assert.truthy(text:find("/lib/Igreja", 1, true))
    assert.truthy(text:find("1 arquivo de áudio copiado (3.0 MB)", 1, true))
    assert.truthy(text:find("/proj/Click.wav", 1, true))
    assert.truthy(text:find("outro computador", 1, true))
  end)

  it("nome que já existe pede confirmação antes de substituir", function()
    existing["Igreja"] = true
    lv.open_export(song)
    assert.equal("confirm", (lv.export()))
    assert.is_nil(written)
    assert.equal("done", (lv.export()))
    assert.is_not_nil(written)
  end)

  it("trocar o nome depois do aviso pede confirmação de novo", function()
    existing["Igreja"] = true
    existing["Outra"] = true
    lv.open_export(song)
    lv.export()
    lv.set_name("Outra")
    assert.equal("confirm", (lv.export()))
  end)

  it("sem nome ou sem poder gravar: erro com o caminho", function()
    lv.open_export(song)
    lv.set_name("  ")
    assert.equal("error", (lv.export()))
    lv.set_name("Igreja")
    write_result = { false, "no_write", { path = "/lib/Igreja/musica.json" } }
    local res, text = lv.export()
    assert.equal("error", res)
    assert.truthy(text:find("/lib/Igreja/musica.json", 1, true))
  end)

  describe("lista da biblioteca", function()
    local items, pkgs, missing, added, dir_ok, set_dir_to, opened
    local list_lib = {
      dir = function() return "/lib", dir_ok end,
      list = function() return items end,
      read = function(f) return pkgs[f] end,
      missing_plugins = function(p) return missing[p.name] or {} end,
      set_dir = function(p) set_dir_to = p or "padrão"; dir_ok = true end,
      open_folder = function(p) opened = p end,
    }
    local fake_import = {
      add = function(p)
        added[#added + 1] = p.name
        return true, p.report or { learn = {}, cc_differs = {}, offline = {} }
      end,
    }

    before_each(function()
      dir_ok, set_dir_to, opened, added, missing = true, nil, nil, {}, {}
      items = {
        { name = "Amazing", folder = "Amazing", ok = true, bpm = 72, signature = "3/4", bars = 64, sections = 5, exported_at = "2026-11-01 20:00" },
        { name = "Futura", folder = "Futura", ok = false, err = "unknown_format" },
        { name = "Igreja", folder = "Igreja", ok = true, bpm = 129.5, signature = "4/4", bars = 85, sections = 1 },
      }
      pkgs = {
        Amazing = { name = "Amazing", report = { learn = { "Reverb" }, cc_differs = {}, offline = { "audio/Click.wav" } } },
        Igreja = { name = "Igreja", report = { learn = { "Reverb", "Rotary" }, cc_differs = { "Wah" }, offline = {} } },
      }
      lv.init({ library = list_lib, song_package = fake_pkg, song_import = fake_import })
      lv.open_list()
    end)

    it("resumo de cada música; a que não abre não pode ser escolhida", function()
      assert.equal("72 BPM · 3/4 · 64 comp. · 5 seções · 2026-11-01 20:00", lv.summary(items[1]))
      assert.equal("129.5 BPM · 4/4 · 85 comp. · 1 seção", lv.summary(items[3]))
      assert.equal("não dá para abrir", lv.summary(items[2]))
      lv.pick("Futura")
      assert.same({}, lv.list_state().picked)
    end)

    it("seleção múltipla na ordem dos cliques, ajustável", function()
      lv.pick("Igreja")
      lv.pick("Amazing")
      assert.same({ "Igreja", "Amazing" }, lv.list_state().picked)
      lv.move(2, -1)
      assert.same({ "Amazing", "Igreja" }, lv.list_state().picked)
      lv.pick("Amazing")
      assert.same({ "Igreja" }, lv.list_state().picked)
    end)

    it("adiciona na ordem e junta Learn, CC diferente e offline", function()
      lv.pick("Igreja")
      lv.pick("Amazing")
      local res, text = lv.add()
      assert.equal("done", res)
      assert.equal("2 músicas adicionadas no fim do projeto.", text)
      assert.same({ "Igreja", "Amazing" }, added)
      local result = lv.list_state().result
      assert.truthy(result:find("faça o Learn): Reverb, Rotary", 1, true))
      assert.truthy(result:find("ficou o desta máquina): Wah", 1, true))
      assert.truthy(result:find("Amazing: audio/Click.wav", 1, true))
    end)

    it("plugins faltando: lista antes e só adiciona se confirmar", function()
      missing.Igreja = { "VST3: ValhallaRoom" }
      lv.pick("Igreja")
      assert.same({ "missing", "VST3: ValhallaRoom" }, { lv.add() })
      assert.same({}, added)
      assert.equal("done", (lv.add_anyway()))
      assert.same({ "Igreja" }, added)
    end)

    it("sem escolha não adiciona nada", function()
      assert.equal("none", (lv.add()))
      assert.same({}, added)
    end)

    it("pasta escolhida ausente: lista vazia e Padrão volta à pasta padrão", function()
      dir_ok = false
      lv.open_list()
      assert.same({ false, {} }, { lv.list_state().dir_ok, lv.list_state().items })
      lv.use_default_dir()
      assert.equal("padrão", set_dir_to)
      assert.equal(3, #lv.list_state().items)
    end)
  end)
end)
