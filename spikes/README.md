# Spikes técnicos: Live Sections

Testes curtos para validar a base técnica antes de escrever a interface.
Para rodar um script: **Actions → Show action list → New action → Load ReaScript…**, escolha o arquivo `.lua` e clique em *Run*.

## 01_ambiente.lua: inventário
1. Rode o script e copie o console.
2. Em **Preferences → Audio → Seeking**, ligue/desligue o *smooth seek* (ou mude o número de compassos).
3. Rode de novo. As config vars que mudaram aparecem com `<- MUDOU`.

**Mande:** o console das duas execuções.

## 02_cancelar_salto.lua: cancelar o salto
Pré-requisitos: smooth seek ligado em **1 compasso**, repeat desligado, um projeto com áudio contínuo (stems ou pad) e pelo menos 2 regiões.

| Teste | Passos | O que observar |
|---|---|---|
| A. Salto normal | Play → `1` | O salto acontece exatamente na virada? Console: `[SALTO]` |
| B. Cancelar cedo | Play → `1` → `C` logo em seguida | A música segue? Console: `[ok] virada … passou sem salto` |
| C. Cancelar em cima da hora | Play → `1` → `C` na última batida antes da virada | Igual ao B, e **escute bem a virada: tem estalo ou falha?** |
| D. GoToRegion | Play → `2` | O salto espera o fim do compasso ou o fim da região atual? |
| E. Cancelar o GoToRegion | Play → `2` → `C` | O cancelamento funciona também nesse caso? |

**Mande:** o console e o que você ouviu no teste C (limpo / estalo / pequena falha).

## 03_monitor_midi.lua: MIDI do controlador
1. Em **Preferences → MIDI Inputs**, deixe o controlador em *Enable input*. Rode o script, aperte pads e mova faders.
2. Mude para *Enable input for control messages* e repita.
3. Com a saída do controlador habilitada em **MIDI Outputs**, os pads devem acender enquanto você os segura.

**Mande:** o console dos dois modos e se os LEDs acenderam.
