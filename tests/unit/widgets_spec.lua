local stub = require("stubs.reaper")

-- ImGui falsa: registra as chamadas e responde conforme `ui` (cliques, menu
-- escolhido, Esc). Sem fontes carregadas, theme.font não empurra nada.
local function fake_imgui(ui)
  local calls = {}
  local last_id
  local im = { MouseButton_Left = 0, MouseButton_Right = 1, Key_Escape = 512, DrawFlags_RoundCornersTop = 48 }
  setmetatable(im, { __index = function(_, name)
    return function(...) calls[#calls + 1] = { name, ... }; return 0, 0 end
  end })
  function im.InvisibleButton(_, id) calls[#calls + 1] = { "InvisibleButton", id }; last_id = id; return ui.pressed == id end
  function im.IsItemClicked(_, button) return ui.clicked and ui.clicked[1] == last_id and ui.clicked[2] == button end
  function im.IsItemHovered() return ui.hovered == last_id end
  function im.IsKeyPressed(_, k) return ui.esc and k == 512 end
  function im.BeginPopup() return ui.popup end
  function im.BeginMenu(_, label) calls[#calls + 1] = { "BeginMenu", label }; return ui.submenu end
  function im.MenuItem(_, label, _, _, enabled)
    calls[#calls + 1] = { "MenuItem", label, enabled }
    return ui.choose == label
  end
  function im.GetItemRectMin() return 10, 20 end
  function im.GetItemRectMax() return 110, 160 end
  function im.GetCursorScreenPos() return 10, 20 end
  function im.CalcTextSize(_, s) return #s * 7, 14 end
  function im.GetDeltaTime() return 1 / 60 end
  function im.CreateFont() return {} end
  return im, calls
end

describe("ui.widgets", function()
  local r, w, im, calls, ui, learn, mappings, theme, anim, dir
  local panic = { action = "panic" }

  local function find(name, pred)
    local out = {}
    for _, c in ipairs(calls) do if c[1] == name and (not pred or pred(c)) then out[#out + 1] = c end end
    return out
  end
  local function texts()
    local out = {}
    for _, c in ipairs(find("DrawList_AddText")) do out[#out + 1] = c[6] end
    return out
  end
  local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

  before_each(function()
    r = stub.install()
    dir = os.tmpname(); os.remove(dir)
    r._resource_path = dir
    for _, m in ipairs({ "ui.widgets", "ui.theme", "ui.anim", "midi.learn", "midi.mappings" }) do package.loaded[m] = nil end
    theme, anim = require("ui.theme"), require("ui.anim")
    learn, mappings = require("midi.learn"), require("midi.mappings")
    w = require("ui.widgets")
    ui = {}
    im, calls = fake_imgui(ui)
    theme.init("ctx", im, "/sem/fontes/")
    mappings.load()
    w.init(im, theme, anim, learn, mappings)
    w.frame("ctx", 0)
  end)

  after_each(function() os.execute("rm -rf '" .. dir .. "'") end)

  describe("describe", function()
    it("mostra tipo, número, canal e porta", function()
      assert.equal("Nota 24 · canal 1\nSMC", w.describe({ msg_type = "note", number = 24, channel = 1, port_name = "SMC" }))
      assert.equal("CC 7 · canal 10\nSMC", w.describe({ msg_type = "cc", number = 7, channel = 10, port_name = "SMC" }))
      assert.equal("Pitch bend · canal 2\nSMC", w.describe({ msg_type = "pb", channel = 2, port_name = "SMC" }))
      assert.equal("Sem mapeamento", w.describe(nil))
    end)
  end)

  describe("mappable", function()
    it("clique direito abre o menu com Learn, Remover e Ver; Learn inicia o learn", function()
      ui.popup, ui.choose = true, "Learn MIDI"
      w.mappable("ctx", panic, "Panic")
      local items = {}
      for _, c in ipairs(find("MenuItem")) do items[#items + 1] = c[2] end
      assert.same({ "Learn MIDI", "Remover mapeamento" }, items)
      assert.equal(1, #find("BeginMenu", function(c) return c[2] == "Ver mapeamento" end))
      assert.same({ mode = "control", control = panic }, learn.state())
    end)

    it("o clique direito no item abre o popup", function()
      im.InvisibleButton("ctx", "btn")
      ui.clicked = { "btn", 1 }
      w.mappable("ctx", panic, "Panic")
      assert.equal(1, #find("OpenPopup"))
    end)

    it("Remover e Ver só ficam ativos com mapeamento; Remover apaga e salva", function()
      ui.popup = true
      w.mappable("ctx", panic, "Panic")
      assert.is_false(find("MenuItem", function(c) return c[2] == "Remover mapeamento" end)[1][3])

      mappings.set({ action = "panic", port_name = "SMC", msg_type = "note", channel = 1, number = 3 })
      ui.choose = "Remover mapeamento"
      w.mappable("ctx", panic, "Panic")
      assert.is_nil(mappings.get("panic"))
      assert.is_not_nil(io.open(mappings.config_path(), "r"))
    end)

    it("durante o learn pulsa em lilás com Aguardando MIDI… e Esc cancela", function()
      learn.start(panic)
      w.mappable("ctx", panic, "Panic")
      assert.is_true(#find("DrawList_AddRect", function(c) return c[7] == theme.C.learn end) > 0)
      assert.is_true(has(texts(), "Aguardando MIDI…"))

      ui.esc = true
      w.frame("ctx", 1)
      assert.is_nil(learn.state())
    end)

    it("no Learn global todos ficam destacados e o clique escolhe o controle", function()
      learn.start_global()
      im.InvisibleButton("ctx", "btn")
      w.mappable("ctx", panic, "Panic")
      assert.is_true(#find("DrawList_AddLine") > 0)          -- contorno tracejado

      ui.clicked = { "btn", 0 }
      w.mappable("ctx", panic, "Panic")
      assert.same(panic, learn.state().control)
    end)

    it("pisca ao receber o comando e o anel some em 0,45 s", function()
      w.flash(panic)
      w.mappable("ctx", panic, "Panic")
      assert.equal(1, #find("DrawList_AddRect"))
      calls = {}
      im, calls = fake_imgui(ui)
      w.init(im, theme, anim, learn, mappings)
      w.flash(panic)
      w.frame("ctx", 0.5)
      w.mappable("ctx", panic, "Panic")
      assert.equal(0, #find("DrawList_AddRect"))
    end)
  end)

  describe("section_card", function()
    local card = { name = "Refrão", color = 0, slot = 4, bars = 8 }

    it("clique dispara a seção; mostra slot, duração e estado", function()
      ui.pressed, ui.clicked = "c1", { "c1", 0 }
      assert.equal("trigger", w.section_card("ctx", "c1", card, 200, 140))
      local t = texts()
      assert.is_true(has(t, "4") and has(t, "8 compassos") and has(t, "PRONTA") and has(t, "Refrão"))
    end)

    it("tocando: borda na cor da região e progresso proporcional", function()
      local playing = { name = "Refrão", color = 0, slot = 4, bars = 8, state = "playing", progress = 0.25 }
      w.section_card("ctx", "c1", playing, 200, 140)
      local clip = find("DrawList_PushClipRect")[1]
      assert.equal(10 + 200 * 0.25, clip[5])
      assert.is_true(has(texts(), "TOCANDO"))
    end)

    it("em loop o progresso continua visível", function()
      w.section_card("ctx", "c1", { name = "Ponte", state = "loop", progress = 0.5 }, 200, 140)
      assert.equal(10 + 100, find("DrawList_PushClipRect")[1][5])
      assert.is_true(has(texts(), "LOOP"))
    end)

    it("na fila: contagem regressiva em batidas e ✕ que cancela", function()
      local queued = { name = "Ponte", color = 0, slot = 5, state = "queued", beats_left = 3 }
      ui.pressed = "c2:x"
      assert.equal("cancel", w.section_card("ctx", "c2", queued, 200, 140))
      local t = texts()
      assert.is_true(has(t, "3") and has(t, "BAT.") and has(t, "NA FILA"))
      assert.equal("c2:x", find("InvisibleButton")[1][2])   -- o ✕ vem antes do card
    end)

    it("no Learn global o clique não dispara a seção", function()
      learn.start_global()
      ui.clicked = { "c1", 0 }
      assert.is_nil(w.section_card("ctx", "c1", { name = "Verso", control = { action = "trigger_slot", arg = 1 } }, 200, 140))
      assert.same({ action = "trigger_slot", arg = 1 }, learn.state().control)
    end)

    it("usa a cor nativa da região", function()
      local native = 0x1000000 | 0x3366CC
      r.ColorFromNative = function(c) return (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF end
      assert.equal(0x3366CCFF, w.region_color(native))
      assert.equal(theme.rgba(theme.DEFAULT_SECTION_COLOR), w.region_color(0))
    end)
  end)
end)
