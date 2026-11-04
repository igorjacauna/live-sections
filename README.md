# Live Sections

Performance ao vivo por seções no REAPER, no estilo do Ableton. Cada música
começa num marcador `SONG: Nome` e as regiões do projeto viram as seções:
dispare com quantize, coloque na fila e cancele até o último instante, prenda
em loop e troque de música pelo controlador MIDI.

Site, demo e instalação: https://live-sections.igor-jacauna-cloudflare.workers.dev

## Recursos

- Saltos quantizados (imediato, batida, 1/2/4/8 compassos, fim da seção); nos
  modos de compasso o salto é feito pelo motor do REAPER, com 0 samples de desvio
- Fila cancelável sem glitch, loop de seção, parada no fim de cada música
- MIDI learn por clique direito, learn global, LEDs por estado com velocity
  configurável (seções, Play, camada ligada); notas, CC, Program Change e pitch bend
- Um Kontakt por música: só o atual armado no teclado, notas seguradas não
  cortam, bypass com cauda, camadas do multi-out com fader, botão Ligado e soft
  takeover; duplo clique no nome da camada para renomear
- Multitracks: as tracks de áudio escolhidas em cada música (bateria, baixo,
  vozes…) ganham fader, medidor e botão Ligado num grupo próprio, ao lado das
  camadas, na Performance e no Palco, com faders e botões do controlador
- Cor das colunas: camadas e multitracks usam a cor da track no REAPER;
  clique direito no nome para trocar
- Mapeamento: knobs, faders e botões do controlador viram um CC fixo só para o
  Kontakt da música atual (por um JSFX), com aprender em série, Enviar p/ Learn,
  Testar, valores por música e LED nos botões liga/desliga
- Parâmetros nas camadas: até 4 controles do Mapeamento fixos em cada camada,
  com nome por música ("Reverb", "Rotary") e valor ou ON/OFF legível de longe;
  "+ parâmetro" e mexa o controle, sem sair da tela de performance
- Modo Editar: faixa de estrutura com dividir, desenhar, arrastar bordas, ímã,
  chips de nome e um passo de undo por operação; avisos com correção
- Tap tempo e alinhamento do compasso 1 para músicas gravadas sem grid
- Biblioteca de músicas: Exportar (modo Editar) salva a música configurada
  (seções, tempo, cifra, anotação, Kontakt com o timbre, camadas, parâmetros e
  áudios) numa pasta; "+ Da biblioteca" monta o setlist num projeto novo, uma
  música depois da outra. Em outro computador, leve a pasta da biblioteca; o
  Kontakt e as bibliotecas dele precisam estar instalados lá
- Cifra por música na janela de cifra e no celular/tablet (navegador, com QR
  Code): seção inteira com barra de progresso; anotação por música (tom, dica);
  no celular, a tela fica acesa enquanto a cifra está aberta
- Modo palco com camadas, multitracks e anotação, e 85 actions para o Action
  List ou o ReaLearn
- O áudio nunca depende do script: se ele fechar, o REAPER continua tocando

## Instalar

Requer REAPER 7+ e a extensão [ReaImGui](https://github.com/cfillion/reaimgui)
(pelo ReaPack). Não usa SWS.

1. Extensions → ReaPack → Browse packages → instale **ReaImGui** e reinicie o REAPER
2. Extensions → ReaPack → Import repositories →
   `https://live-sections.igor-jacauna-cloudflare.workers.dev/index.xml`
3. Browse packages → **Live Sections** → Install → Apply
4. Actions → Show action list → rode **LiveSections.lua**
5. Opcional: para abrir com um clique, ponha a ação no menu Extensions
   (Options → Customize menus/toolbars → Main extensions), numa barra de
   ferramentas ou num atalho. O passo a passo está em Configurações → Abrir
   mais rápido

Instalação manual: copie a pasta `LiveSections/` para a pasta `Scripts` do REAPER.

## Desenvolvimento

```
LiveSections/        o pacote (script principal, core/, midi/, ui/, actions/)
tests/unit/          testes busted com um stub da API do REAPER
tests/CHECKLIST.md   roteiro de integração no REAPER
tests/fixtures/      show_teste.rpp (3 músicas, 4/4 e 7/8)
spikes/              experimentos que validaram decisões no REAPER
prototype/           protótipo clicável da interface
site/                página do site
tools/               geradores das actions, do index.xml e do site
```

- Testes: `busted` na raiz (Lua 5.4)
- Actions: `lua tools/gerar_actions.lua`
- Site: `sh tools/build_site.sh && wrangler deploy`

## Licença

GPL-3.0-or-later. Veja [LICENSE](LICENSE). As fontes em
`LiveSections/assets/fonts` (Manrope e JetBrains Mono) estão sob a SIL Open
Font License, com os textos ao lado.
