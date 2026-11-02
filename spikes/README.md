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

## 04_midi_control_mode.lua: modo "control" (RF-047)
O script cria uma track temporária **"Spike 04 (teste)"** com ReaSynth, armada em *All MIDI inputs*, e a remove quando termina.

| Rodada | Preferences → MIDI Inputs (controlador, porta *Master*) | O que fazer | O que observar |
|---|---|---|---|
| A | *Enable input* | Rode o script, aperte 3 pads, pare o script | Os pads aparecem no console? Acendem? **Tocam som no ReaSynth?** |
| B | *Enable input for control messages* | Rode o script, aperte os mesmos 3 pads, pare o script | Os pads aparecem no console? Acendem? **Tocam som no ReaSynth?** |

Deixe a porta *Private* desabilitada nas duas rodadas, para não duplicar os eventos.
Para parar o script, rode-o de novo e escolha **Terminate instances**: o resumo aparece no fim do console.

**Mande:** o console das duas rodadas e, para cada uma, se os pads acenderam e se tocaram som.

**Resultado (2026-10-31, SINCO SMC-Mixer, porta *Master*; *Private* desabilitada):**

| Rodada | No console | LEDs (saída habilitada) | Som nas tracks |
|---|---|---|---|
| A, *Enable input* | sim, `dev=0x4` | acendem | sim |
| B, *Enable input for control messages* | sim, `dev=0x10004`, cada evento duas vezes | acendem | não |

O modo de controle funciona e o RF-047 fica na V0. Para a leitura (task 3.1):
a porta é `devIdx & 0xFFFF` e a cópia duplicada de cada evento é descartada.
Os botões mandam Note On/Off (padrão Mackie: Rec = nota 0, Solo = 8,
Select = 24) e cada fader manda pitch bend no próprio canal, com 7 bits úteis
(`E0 00 xx`). Os LEDs só acendem com a saída habilitada em MIDI Outputs.

## 05_salto_imediato.lua: salto imediato com smooth seek ligado
Não precisa de controlador. Use um projeto com áudio contínuo. O script liga o smooth seek, desliga o repeat e, se o projeto não tiver regiões, cria a região **"Alvo"** nos compassos 1 a 4. Todos os saltos vão para o início da 1ª região.

1. Rode o script e dê play a partir do compasso 9 ou depois, para o salto ser bem audível.
2. Com a janela do spike em foco, aperte **1**, espere o salto, volte a tocar lá na frente e repita com **2** e com **3**. Faça cada tecla umas 3 vezes, em pontos diferentes do compasso.
3. Feche com **Esc**.

| Tecla | O que o script faz | O que se espera |
|---|---|---|
| 1 | Seek comum, com o smooth seek ligado | Esperar a virada do compasso (é o controle) |
| 2 | Desliga o smooth seek, faz o seek e religa na mesma hora | Se der "IMEDIATO", o Live Sections já funciona assim |
| 3 | Desliga o smooth seek, faz o seek e religa no ciclo seguinte | Alternativa, caso a 2 espere o compasso |

**Mande:** o console e se ouviu estalo em algum salto.

## 06_alinhar_tempo.lua: "Marcar compasso 1" sem mexer no áudio (RF-098, RF-099)
Não precisa de controlador nem de áudio.

1. Abra uma aba de projeto nova e vazia: **File → New project tab**, sem mudar nenhuma configuração. O script recusa rodar num projeto que já tenha tracks ou marcadores.
2. Rode o script. Ele monta sozinho um cenário com duas músicas, itens vazios e regiões, alinha a música B, depois alinha a música A com o código real do Live Sections (`core/tempo_align.lua`) e imprime o resultado.
3. Feche a aba **sem salvar**.

O console lista os marcadores de tempo antes e depois e confere quatro coisas, cada uma com **ok** ou **FALHOU**:
1. Itens, marcadores e regiões ficaram no lugar.
2. O compasso 1 da música A começa exatamente no ponto marcado.
3. A música B manteve o tempo dela e o compasso 1 dela continua no lugar.
4. O ajuste fino (+0,01 BPM e +1 ms) também não move nada.

**Mande:** o console inteiro.

## 08_cc_para_kontakt.lua: CC para o Kontakt por um JSFX
Base dos "Controles do Kontakt" (como no Gig Performer: o knob vira um CC fixo que só o Kontakt da música atual recebe).
1. Selecione a track do Kontakt, rode o script e clique **Instalar na track selecionada** (instala o gerador e um monitor de CC antes do Kontakt).
2. **A. CC via JSFX**: mexa o slider **Valor** e anote os contadores. **blocos** sobe sozinho? **enviados** e **recebidos** sobem ao mexer?
3. No Kontakt, clique direito num knob → **Learn MIDI CC# Automation** e mexa o **Valor** de novo: o knob aprende e segue?
4. **B. Parâmetro do Kontakt**: na aba Auto do Kontakt → Host Automation, arraste o **#000** para um knob; no spike, deixe **Parâmetro** em 0 e mexa o **Valor do parâmetro**: o knob segue?
5. Toque o teclado enquanto mexe: as notas continuam normais?
6. Clique **Remover** no fim.

**Mande:** o console, os contadores do passo 2 e o que aconteceu nos passos 3 a 5.
