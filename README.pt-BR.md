<!-- Banner -->
<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:0F0E0D,35:8C4A32,70:D97757,100:F5E6D3&height=240&section=header&text=claude-account-manager&fontSize=52&fontColor=F5E6D3&animation=fadeIn&fontAlignY=38&desc=Troque%20de%20conta%20do%20Claude%20Code%20no%20macOS%20%E2%80%94%20um%20comando%2C%20sem%20re-login&descAlignY=60&descSize=16" />
</div>

<!-- Typing -->
<div align="center">
  <img src="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=21&duration=2800&pause=900&color=D97757&center=true&vCenter=true&width=840&lines=Troque+entre+contas+do+Claude+Code+com+um+comando;Segredos+s%C3%B3+no+Keychain+%E2%80%94+nada+de+token+em+dotfile;Todas+as+camadas+de+auth+trocadas+atomicamente;doctor+%C2%B7+status+%C2%B7+probe+%E2%80%94+nunca+imprimem+segredo" />
</div>

<!-- Status -->
<div align="center">
  <img src="https://img.shields.io/badge/Plataforma-macOS-0F0E0D?style=for-the-badge&logo=apple&logoColor=F5E6D3" />
  <img src="https://img.shields.io/badge/Segredos-S%C3%B3%20Keychain-D97757?style=for-the-badge&logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/Para-Claude%20Code-D97757?style=for-the-badge&logo=anthropic&logoColor=white" />
  <img src="https://img.shields.io/badge/Runtime-Bash%20%2B%20jq-8C4A32?style=for-the-badge&logo=gnubash&logoColor=F5E6D3" />
  <img src="https://img.shields.io/badge/Licen%C3%A7a-MIT-25a162?style=for-the-badge" />
</div>

> O **claude-account-manager** transforma cada conta do Claude Code num perfil nomeado e troca todas com um único comando: sem re-login, sem reboot, sem token colado em dotfile, sem fallback silencioso pra conta errada. Segredos vivem exclusivamente no Keychain do macOS.

> Não afiliado nem endossado pela Anthropic. "Claude" e "Claude Code" são marcas da Anthropic.

[Read in English](README.md)

<br>

## O que é

```yaml
produto:      trocador multi-conta do Claude Code no macOS
contas:       perfis nomeados — setup-token OAuth ou /login nativo
cofre:        só o Keychain do macOS (zero segredo em dotfile, JSON ou log)
troca:        claude-account use <nome> — atômica em todas as camadas
camadas:      slots do Keychain · slot nativo (agents) · launchctl · ~/.claude.json · daemon · shells
segurança:    credencial deslocada é arquivada antes, verificada por fingerprint
diagnóstico:  doctor · status · probe (fingerprints SHA-256, nunca segredos)
extras:       medição de rate limit · troca automática · regime de cota · override CLAUDE_NATIVE_BIN
```

## O problema

O Claude Code resolve autenticação por várias camadas ao mesmo tempo: a variável
`CLAUDE_CODE_OAUTH_TOKEN`, uma credencial nativa no Keychain (`Claude Code-credentials`), metadado
de conta em `~/.claude.json`, seus shells de login e um daemon de fundo. Trocar só uma dessas
camadas deixa outra vencer em silêncio.

A armadilha clássica: você parte de um setup-token, faz `/login` numa segunda conta e depois não
consegue voltar pro token sem reiniciar a máquina, porque a credencial nativa que o `/login`
gravou no Keychain sombreia o token.

A segunda armadilha é o `claude agents`. O daemon por trás dele não repassa o
`CLAUDE_CODE_OAUTH_TOKEN` às sessões em segundo plano que cria, então elas autenticam só pelo slot
nativo do Keychain. Com o token só no shell, o terminal roda numa conta e cada agent de fundo no que
estiver no slot, ou em nada. Por isso o `use` também projeta o setup-token ativo nesse slot.

## Arquitetura

```
              ~/.config/claude-account/active          (nome do perfil, sem segredo)
                              │
      claude (wrapper) ──▶ exec sob o perfil ativo ──▶ binário claude real
                              │
        ┌──────────────────┬──┴──────────────────┬──────────────────┐
        ▼                  ▼                     ▼                  ▼
  Keychain do macOS   slot nativo          launchctl env      ~/.claude.json
  slots por perfil (daemon, claude agents) CLAUDE_CODE_OAUTH_TOKEN metadado de conta
        └──────────────────┴─────────────────────┴──────────────────┘
                              │
        claude-account use <nome>  = troca TODAS atomicamente,
        arquivando todo login que desloca (a troca nunca destrói um login)
```

## Quick start

```bash
git clone https://github.com/ricardo-landim/claude-account-manager.git
cd claude-account-manager
bash install.sh
```

Adicione ao `~/.zprofile` a linha que o instalador imprime:

```bash
[ -r "$HOME/.local/lib/claude-account-manager/shell-init.zsh" ] && \
  source "$HOME/.local/lib/claude-account-manager/shell-init.zsh"
```

Registre o `/login` atual como perfil, adicione a segunda conta por setup-token
(rode `claude setup-token` logado nela) e troque à vontade:

```bash
claude-account import-native pessoal
claude-account add-oauth trabalho
claude-account use trabalho
claude-account use pessoal
```

> [!NOTE]
> O `use` move as sessões em background para a conta nova (mesmos ids, inclusive as que estiverem
> ocupadas) e reinicia o [Orca](https://orca.dev) (se instalado) para os terminais abertos trocarem
> também. `--keep-agents` deixa as sessões em background na conta delas; `--no-restart` não para
> nada. Shells e agentes novos sempre pegam o perfil ativo; sessões já abertas ficam na conta
> anterior até reiniciar. O trocador automático (`claude-account-autoswitch`) passa `--no-restart`,
> mais `--move-agents` quando a política tem `"move_agents": true`.

## Comandos

| | Comando | O que faz |
|:---:|---|---|
| ➕ | `add-oauth <nome>` | registra um perfil por setup-token (validado antes de guardar) |
| ♻️ | `renew <nome>` | renovação guiada de um setup-token vencido: browser, checagem, guarda, medição |
| 🧙 | `wizard` | tela interativa (setas): contas e cotas, trocar, renovar, doctor |
| 📥 | `import-native [nome] [--last-login]` | importa o `/login` atual (ou o último que o `use` deslocou) como perfil |
| 🔁 | `use <nome>` | troca todas as camadas de auth pro perfil, atomicamente, slot nativo incluído |
| 📋 | `list` | perfis, o ativo marcado com `*` |
| 🩺 | `doctor` | checa divergência em todas as camadas |
| 📊 | `status` | perfil ativo + fingerprints (nunca os segredos) |
| 🧪 | `probe` | autentica e roda uma inferência mínima |
| 📈 | `measure [nome...]` | estado das janelas de 5h e 7d por perfil, lido dos headers de resposta |
| 🚦 | `regime [--json]` | uma palavra dizendo o que a cota permite agora |
| ▶️ | `exec [args...]` | roda o binário nativo sob o perfil ativo (o que o wrapper faz) |
|  | `login <nome>` | login completo de um perfil OAuth, feito uma vez, num item próprio do Keychain (conectores do claude.ai) |
|  | `update [--apply [versão]]` | Claude Code: versão instalada, a mais nova e as sessões em background; `--apply` instala pelo instalador nativo, troca o `claude-stable` por rename atômico, espera o daemon adotar as sessões e depois as reinicia (mesmos ids) junto com o Orca já na versão nova, como na troca de conta; `--no-restart` deixa elas na versão antiga até ficarem ociosas |
|  | `bg-restart [--force]` | move as sessões em background para o perfil ativo, mesmos ids (adia se alguma estiver ocupada) |
|  | `bg-status` | perfil ativo contra o do daemon, sessões em background, troca pendente |

## Sessões em background

O daemon do `claude agents` guarda o ambiente de quem o criou, então o `use` move as sessões dele
em vez de pará-las: anota quais estão vivas, reinicia o daemon a partir do ambiente do perfil novo
e retoma cada uma pelo mesmo id, com um prompt curto avisando que os monitores e shells em
background morreram no reinício. Na troca manual, uma sessão ocupada é interrompida e volta com
esse prompt. Na troca automática, a sessão ocupada adia a troca (o ciclo do autoswitch conclui
quando todas estiverem ociosas, com `"move_agents": true` na política). O `claude-account bg-status` mostra se o
daemon está no perfil ativo.

O `claude-sessions` cuida delas uma a uma, sempre no perfil ativo:

```
claude-sessions                                   # sessões vivas: id, nome, status, cor, modo
claude-sessions new --name RELATORIOS --dir ~/trabalho/app --color cyan --prompt "Monte o relatório de hoje"
claude-sessions resume RELATORIOS                 # mesmo id, nunca uma cópia
claude-sessions rename RELATORIOS NOTURNO         # também: color <alvo> <cor>, mode <alvo> <modo>
claude-sessions stop NOTURNO                      # a conversa fica salva
claude-sessions account secondary                 # troca de conta e leva todas as sessões
```

Crie sessões em background por ele (ou por `claude-account exec --bg`), nunca com `claude --bg`
direto de um processo que pode carregar o ambiente de outra conta.

### Conectores num perfil OAuth

O setup-token só tem escopo de inferência, então os conectores do claude.ai nunca carregam com ele.
O `claude-account login <nome>` faz uma vez um login completo do perfil, guardado num item próprio
do Keychain; dali em diante o perfil roda nele (o setup-token fica só para o `measure`) e a troca
de conta nunca mais abre o navegador.

## Wizard

`claude-account wizard` é o mesmo motor atrás de uma tela: cada perfil com as barras de cota de
5h e 7d, e trocar, renovar ou rodar o doctor pelas setas. Renovar um token percorre os três
passos (login no browser, checagem, guarda) e nunca imprime o token: o wizard lê o prompt de
código do `claude setup-token`, entrega o código e captura o token no caminho pro Keychain.

<div align="center">
  <img src="docs/wizard-home.png" width="720" alt="claude-account wizard: contas com barras de cota e o menu" />
  <br><br>
  <img src="docs/wizard-renew.png" width="720" alt="claude-account wizard: token renovado em três passos" />
</div>

Precisa de `node` (22 ou mais novo, exigência do Ink 7) e de `python3` (vem com as ferramentas de linha de comando do Xcode; ele empresta um pseudo-terminal ao `claude setup-token`); o `install.sh` instala quando o node existe e pula quando
não, a CLI funciona igual sem ele. `renew <nome>` faz o mesmo fluxo em bash puro, e
`renew <nome> --token-stdin` guarda um token vindo do stdin (o que o wizard chama).

## Rate limit, troca automática e regime de cota

Três peças em cima da troca de perfil, tudo shell + `jq`, sem dependência nova.

### `measure`

Manda uma requisição de um token à API com o token de cada perfil e lê os headers
`anthropic-ratelimit-unified-*` da resposta: utilização e horário de reset das janelas de 5 horas
e 7 dias, e se a conta está pagando excedente. Imprime só fingerprints, nunca um token. Perfil
nativo (`/login`) não tem setup-token pra medir; dê um da mesma conta:

```bash
claude-account add-oauth pessoal-medida --measure-for pessoal
```

### `claude-account-autoswitch`

Um job pra launchd ou cron, a cada 5 minutos. Mede os dois perfis nomeados em
`~/.config/claude-account/policy.json`, move o perfil ativo pro `fallback` quando o `preferred`
bate os limiares de esgotamento, e volta quando o `preferred` tem folga de novo (histerese,
intervalo mínimo entre trocas e teto diário). Também grava o `measure.json` com as últimas 24
amostras por perfil, pra status line ou qualquer outro leitor consumir um arquivo em vez de chamar
a API.

```json
{
  "preferred": "trabalho",
  "fallback": "pessoal",
  "exhausted_at": {"five_hour": 0.95, "seven_day": 0.97},
  "return_below": {"five_hour": 0.70, "seven_day": 0.90},
  "min_switch_interval_min": 10,
  "max_switches_per_day": 12
}
```

Botão de desligar: `touch ~/.config/claude-account/autoswitch.off`. Log: `autoswitch.log`. Perfil
fora da política ativado à mão nunca é sobrescrito, e uma troca manual entre os dois perfis da política é respeitada até a conta escolhida esgotar enquanto a outra tem folga. Experimente com `--dry-run` antes. Um
LaunchAgent que roda a cada 5 minutos:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.claude-account.autoswitch</string>
  <key>ProgramArguments</key><array><string>/Users/VOCE/bin/claude-account-autoswitch</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
```

Salve como `~/Library/LaunchAgents/local.claude-account.autoswitch.plist` e carregue com
`launchctl bootstrap gui/$(id -u) <caminho>`.

### `regime`

Uma palavra que diz o que a cota permite agora, projetada pelo ritmo médio de cada janela da conta
que **esta sessão** realmente usa (uma troca nunca move sessão que já está rodando):

| Regime | Significado |
|---|---|
| `livre` | reserva no reset é confortável, nada a fazer |
| `atencao` | no ritmo de chegar perto do limite, só aviso |
| `economia` | nesse ritmo uma janela esvazia antes do reset; trabalho pesado é rebaixado |
| `pouso` | seria `economia`, mas o reset de 5h está perto e o ritmo recente cabe abaixo de 100% |
| `trava` | as duas contas fora (rejeitadas ou pagando excedente), medido como tal |

Mudança exige duas medições seguidas, `economia` segura 15 minutos, `trava` é imediata nos dois
sentidos porque é fato medido, e medição com mais de 15 minutos (ou sonda morta) nunca trava nada.
Override com validade: `regime livre --por 30m`, `regime economia --por 1h`, `regime auto`. Em
`economia` ou `trava`, o `exec` (e portanto o wrapper `claude`) abre a sessão nova com
`--effort medium`, a menos que você passe `--effort`. Hooks e status line leem `regime --json`
(uns 30 ms, sem rede). Ajustes ficam no `policy.json` sob `"regime"`.

Por que projeção de ritmo em vez de "uso acima de N%": limiar reage tarde. Nas duas manhãs de uma
semana de transcrições reais em que uma janela de 5h passou de 100%, um limiar de 80% avisou 20 e
75 minutos antes; a projeção avisou umas 3 horas antes, com 35 minutos de freio desnecessário na
semana inteira. Testes de cenário offline: `tests/regime-scenarios.sh`.

## Troubleshooting

> [!WARNING]
> Depois de adotar a ferramenta, troque de conta **somente** via `claude-account use`, nunca pelo
> `/login` dentro do Claude Code. Um `/login` direto grava uma credencial nativa que sombreia o
> perfil de setup-token ativo, e o estado diverge em silêncio.

Se acontecer mesmo assim, o `doctor` pega, porque os agents de fundo rodariam naquele login:

```
[FAIL] a /login sits in the native slot: background agents run on that account, not on 'trabalho' (fix: claude-account use trabalho)
[warn] 1 of 3 open session(s) run on another account (pid 51821): restart them to use 'trabalho'
```

A correção é um comando, sem reboot: `claude-account use <perfil-ativo>`. O `/login` achado no slot
nunca é apagado: fica guardado como `Claude Code-credentials-last-login-archive`, e
`claude-account import-native <nome> --last-login` o transforma em perfil. Testes de cenário
offline da troca: `tests/switch-scenarios.sh`; dos perfis com login completo, das sessões em background e do `claude-sessions`: `tests/bg-sessions-scenarios.sh`.

## Requisitos

- macOS (a CLI `security` do Keychain é o cofre)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) instalado
- `jq` (`brew install jq`)
- shells de login zsh (o padrão do macOS)

`~/bin` precisa vir **antes** do diretório do Claude Code no `PATH` (o instalador avisa se não
vier). Instalação em lugar incomum? Aponte com `CLAUDE_NATIVE_BIN=/path/to/claude`.

## Notas de segurança

- Tokens são validados contra `claude auth status` antes de serem guardados.
- `status` e `doctor` imprimem fingerprints SHA-256, nunca segredos.
- Toda remoção do slot ativo do Keychain é precedida de uma cópia de arquivo, verificada por
  fingerprint.
- Os metadados de conta em `~/.claude.json` recebem backup antes de serem removidos.
- Em máquinas sem Orca, o helper de reinício é pulado por inteiro e nada é derrubado; o trocador
  automático nunca reinicia o Orca.
- `measure` gasta um token de saída por perfil por rodada e imprime só fingerprints.

## Docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — invariantes e ADRs
- [`install.sh`](install.sh) — o que vai pra onde (`~/bin`, `~/.local/lib`, `~/.config`)

---

## Feito pela Six Quasar

A **Six Quasar** constrói agentes de IA que trabalham de verdade: WhatsApp como interface, núcleo
determinístico, IA na borda. Esta ferramenta nasceu da operação diária de múltiplas contas do
Claude Code nessa frota.

<a href="https://github.com/ricardo-landim"><img src="https://img.shields.io/badge/Perfil%20no%20GitHub-181717?style=for-the-badge&logo=github&logoColor=white" /></a>
<a href="https://sixquasar.shop"><img src="https://img.shields.io/badge/sixquasar.shop-D97757?style=for-the-badge&logo=safari&logoColor=F5E6D3" /></a>

<!-- Footer -->
<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:D97757,40:8C4A32,100:0F0E0D&height=120&section=footer" />
</div>
