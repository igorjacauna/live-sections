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
end)
