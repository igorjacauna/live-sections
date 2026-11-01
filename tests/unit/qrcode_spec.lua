local qr = require("core.qrcode")

-- Referência gerada pelo segno (nível M, máscara 0) para o mesmo texto.
local GOLDEN = {
  "11111110001110010101101111111",
  "10000010110010010101001000001",
  "10111010010100010010101011101",
  "10111010011110000001101011101",
  "10111010111011110001101011101",
  "10000010000100111101001000001",
  "11111110101010101010101111111",
  "00000000011001001101000000000",
  "10101010001011011111000010010",
  "01001000100110001000001101001",
  "01100111011110100100111110111",
  "10011100100011010110011101010",
  "10100110110101011101001101011",
  "11111100010101101000001101101",
  "10101011010000001000000000011",
  "00000001000001011100010011010",
  "11101011111111000100001000011",
  "00111101110000001000011100101",
  "10011011100000000010110001011",
  "01110100011001100110011101010",
  "10101110110101001100111110000",
  "00000000100110001110100010111",
  "11111110001100000101101011011",
  "10000010001101011101100011011",
  "10111010110100101100111111000",
  "10111010010001001101110011011",
  "10111010100001000001010011101",
  "10000010001111000111110001010",
  "11111110111100100100101001011",
}

local function rows(m)
  local out = {}
  for i, row in ipairs(m) do
    local t = {}
    for _, c in ipairs(row) do t[#t + 1] = c and "1" or "0" end
    out[i] = table.concat(t)
  end
  return out
end

describe("core.qrcode", function()
  it("igual à referência para o endereço da página (versão 3, máscara 0)", function()
    local m, size = qr.encode("http://192.168.0.23:8080/livesections.html", 0)
    assert.equal(29, size)
    assert.same(GOLDEN, rows(m))
  end)

  it("escolhe a menor versão que cabe e recusa texto longo demais", function()
    local _, s1 = qr.encode("a")
    local _, s9 = qr.encode(string.rep("w", 180))
    assert.same({ 21, 53 }, { s1, s9 })
    assert.same({ nil, "too_long" }, { qr.encode(string.rep("w", 181)) })
  end)

  it("sem máscara forçada, mantém os padrões de posição nos três cantos", function()
    local m, size = qr.encode("http://10.0.0.7:8080/livesections.html")
    for _, c in ipairs({ { 1, 1 }, { 1, size - 6 }, { size - 6, 1 } }) do
      local y, x = c[1], c[2]
      assert.is_true(m[y][x] and m[y + 6][x + 6] and m[y + 3][x + 3])
      assert.is_false(m[y + 1][x + 1])
    end
  end)
end)
