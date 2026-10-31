# Checklist de integração no REAPER

Roteiro para validar o Live Sections no REAPER, sobre `tests/fixtures/show_teste.rpp`.
Marque cada item e anote o que falhar (de preferência com vídeo).

## Preparação

- [ ] Instalar pelo ReaPack a partir do `index.xml` local: Extensions → ReaPack →
      Import repositories, colar `file:///…/live-sections/index.xml`, depois
      Browse packages → Live Sections → Install → Apply
- [ ] O script e as 75 actions "Live Sections - …" aparecem na lista de actions
- [ ] Abrir `tests/fixtures/show_teste.rpp` ("Salvar como" numa pasta de teste
      para não alterar o arquivo do repositório)
- [ ] Ligar o metrônomo para ter som sem Kontakt
- [ ] Controlador em "Enable input for control messages" e com a saída MIDI ativa

O projeto tem:

| Música | Tempo | Seções |
|---|---|---|
| Rua Augusta (0–64 s) | 120 BPM, 4/4 | Intro, Verso, Refrão, **trecho sem seção** (48–56 s), Outro |
| Maré Alta (64–114 s) | 96 BPM, 4/4 | Intro, Verso, Refrão |
| Sete por Oito (114–150 s) | 140 BPM, **7/8** | A, B, A 2 |

A track "KONTAKT AQUI - Rua Augusta" é onde entra o Kontakt para os testes de camadas.

## Abertura e robustez

- [ ] Sem a ReaImGui, o script mostra a mensagem com as instruções do ReaPack (RF-100)
- [ ] A janela abre com pelo menos 720×480, mesmo depois de redimensionada
- [ ] Projeto novo sem regiões: tela vazia com "+ Seção" (RF-101)
- [ ] **Fechar o script com o REAPER tocando: o áudio continua** (RF-107)
- [ ] Ao fechar, os LEDs mapeados apagam

## Disparo, fila e cancelamento

- [ ] Parado, clicar num card: toca daquela seção na hora
- [ ] Tocando, disparar outra seção com quantize 1 compasso: card e LED em "na
      fila" com a contagem de batidas, salto na virada
- [ ] Disparar de novo a seção que está na fila: a fila é cancelada
- [ ] Disparar outra seção com uma já na fila: a nova substitui a anterior
- [ ] Cancelar **antes** da entrega (mais de 1 compasso antes): nenhum salto
- [ ] Cancelar **no último compasso** (depois da entrega ao REAPER): nenhum
      salto e nenhum glitch audível
- [ ] Cada quantize: Imediato, Batida, 1, 2, 4 e 8 compassos, Fim da seção
- [ ] "Fim da seção" no Refrão de Rua Augusta (seguido do trecho sem seção)
- [ ] Quantize em Sete por Oito (7/8) cai na linha de compasso de 1,5 s
- [ ] Apagar a região da seção que está na fila: a fila é cancelada (RF-103)
- [ ] Pad mapeado num slot sem seção: ignorado e LED apagado (RF-102)
- [ ] O primeiro salto com smooth seek nativo não dá clique (já ouvido uma vez; confirmar)

## Loop, troca e fim de música

- [ ] Loop ligado: a seção repete e a barra de progresso volta a cada volta
- [ ] Desligar o loop: a música segue para a próxima seção
- [ ] Trocar de música pela setlist, pela barra de ações e pelo controlador
- [ ] Mudança de tempo entre músicas (120 → 96 → 140 BPM) e de fórmula (4/4 → 7/8) respeitadas (RF-104)
- [ ] Fim da música: o REAPER para no fim e o cursor vai para a próxima música
- [ ] Panic: para, solta as notas e volta ao início da música atual
- [ ] Confirmar que a action 40345 é "Send all-notes-off to all MIDI outputs/plug-ins"

## MIDI: learn, LEDs e modos

- [ ] Clique direito → Learn MIDI em card, quantize, setlist, faders, M/S e barra de ações
- [ ] Learn global (Configurações → Learn global): clicar num controle e tocar o controlador
- [ ] Mesma mensagem em duas portas: só a porta aprendida responde
- [ ] Fader do SMC-Mixer (pitch bend) aprendido num volume de camada
- [ ] LEDs: tocando, na fila (pisca), loop e parado, com as velocities das Configurações
- [ ] Configurações → Testar acende os LEDs com cada velocity
- [ ] Desconectar o controlador: pílula "MIDI desconectado"; reconectar volta a funcionar
- [ ] Controlador em "Enable input" (sem control messages) também funciona
- [ ] **Pads e faders do controlador nunca tocam notas no Kontakt**

## Actions da lista do REAPER (5.1)

- [ ] Com o script aberto, disparar 3 actions pelo Action List (ex.: "Disparar seção 02", "Loop liga-desliga", "Quantize 2 compassos")
- [ ] Sem o script aberto, uma action avisa que ele não está aberto
- [ ] "Camada 1 volume (CC)" ligada a um knob: o volume segue o knob

## Modo Editar

- [ ] Montar uma música do zero: "+ Música", desenhar, dividir (clique e `S`), arrastar bordas, juntar, remover
- [ ] Ctrl/Cmd+Z desfaz **um passo por operação**
- [ ] Chips de nome com cor e numeração ("Verso 2"); duração digitada em compassos
- [ ] Renomear a música
- [ ] Ímã: desenho e borda grudam nas bordas das seções e no início/fim da música
- [ ] Clique seleciona sem tocar; duplo clique toca; espaço toca e para
- [ ] Nenhuma sequência de edições produz sobreposição ou seção fora do compasso
- [ ] Criar uma sobreposição na régua do REAPER: aviso com correção de um clique

## Tempo (música sem grid)

- [ ] Gravar ou importar um áudio sem grid (tempo constante) numa música nova
- [ ] TAP 4+ vezes, escolher o arredondamento, marcar o compasso 1 no cursor
- [ ] Ajuste fino ±0,01 BPM e ±1 ms ouvindo o metrônomo
- [ ] Confirmar que o botão Metrônomo usa a action 40364 ("Options: Toggle metronome")
- [ ] A música seguinte não muda de tempo
- [ ] Tudo em menos de 2 minutos

## Kontakt e camadas (pendente: requer Kontakt)

- [ ] Configurações → teclado escolhido; a entrada do Kontakt passa a ser só ele
- [ ] Assistente num Kontakt com 2 saídas: cria 2 filhas recebendo 1/2 e 3/4
- [ ] **Nível de cada camada correto: nenhuma muda nem dobrada** (a track do
      Kontakt também manda 1/2 direto ao master; conferir a camada 1)
- [ ] Assistente num Kontakt que já tem filhas: só vincula, sem duplicar
- [ ] Trocar de música com tecla ou sustain segurados: nenhuma nota presa
- [ ] Kontakt da música anterior entra em bypass depois da cauda
- [ ] Faders de camada com soft takeover: "SUBA/DESÇA O FADER" e nenhum salto de volume
- [ ] Música sem Kontakt: faixa de camadas oculta e aviso no modo Editar (RF-105)
- [ ] Apagar a track do Kontakt: vínculo quebrado no painel de avisos (RF-106)

## Configurações

- [ ] Alterar cada configuração, fechar e reabrir o script: tudo persiste
- [ ] Tolerância: disparo até N ms depois da virada conta como antes dela

## Precisão (loopback)

1. Ligar o metrônomo com click em cada batida
2. Rotear a saída do REAPER de volta para uma entrada (loopback) e gravar numa track
3. Fazer saltos em cada quantize e medir, na gravação, o desvio do click na virada

- [ ] Compasso, N compassos e fim da seção: **0 samples** de desvio
- [ ] Batida e imediato: **menos de 35 ms**

## Show completo

- [ ] Tocar as 3 músicas do início ao fim **só pelo controlador**, sem olhar a tela
- [ ] Modo palco legível de longe; 60 fps com 3 músicas e 20 seções
