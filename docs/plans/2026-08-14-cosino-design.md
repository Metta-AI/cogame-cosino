# Cosino: no-limit Texas Hold'em coworld

A poker coworld on the cogame-parley technology stack: Nim game server
implementing the Coworld runtime contract, LLM-driven decisions where **a
policy is just a prompt**, an always-legal scripted baseline, a shared pure
`sim` module driving the server, the tests, and a static wasm replay viewer,
and cog sprites at a felt table.

## Game shape

- **No-limit Texas Hold'em**, one table, **2–6 seats** (`num_agents`).
- Every seat buys in for `startingStack` chips (default **100**); blinds
  default **1/2**. No rebuys: a busted seat sits out the rest of the episode.
- An episode plays up to `hands` hands (default 30, capped by the episode
  call budget) or until one seat holds every chip, or the platform play
  deadline forces an early stop between hands.
- The button rotates every hand; standard heads-up rules when two remain
  (button posts the small blind and acts first preflop, last postflop).
- Full NLHE betting: fold / check / call / bet / raise / all-in, min-raise
  rules (a short all-in does not re-open betting), side pots, split pots
  with odd-chip-to-first-seat-left-of-button.

## Scoring

`scores[i] = finalStack[i] / totalChipsInPlay` — the chip share, in [0,1],
summing to 1, comparable across episodes regardless of seat count. `win` is
the seat(s) with the biggest final stack. Raw stacks ride along in results.

## Anonymity

As in parley: seats play under anonymous cog aliases (Sprocket, Gizmo, …)
drawn from the seed; policy display names never reach any prompt. Spectator
and replay viewers map aliases back to policy names; results attribute by
policy name.

## Hidden information

Hole cards are the only secret. The deal event for a seat is redacted from
every other player's websocket view (parley's `redactCards` pattern); the
global spectator feed and the replay keep everything. Showdown emits reveal
events that make the called hands public in every view; folded hands are
never revealed to players.

## Decisions: LLM with scripted fallback

The game server owns every decision, exactly like parley:

- Per action, the server composes: rules, the seat's stack / hole cards /
  pot / board / legal actions with amounts, the hand's action history, match
  standings, plus the seat's operator prompt — and asks Claude for
  `{"say": "...", "action": "fold|check|call|raise|allin", "amount": N}`.
  Table talk rides on the action reply (no separate reaction calls — poker
  already spends many calls per hand; the call budget caps `hands`).
- Any illegal or failed reply falls back to the **scripted bot** so the game
  always advances. No credentials → every seat plays scripted, so offline
  certification completes.
- Transports ported from parley: Bedrock sidecar first, Anthropic API second.

**Scripted baseline** (also a fieldable policy): rule-based —
preflop hand-strength buckets (pairs, high-card/suited/connected chart) with
position- and price-aware raise/call/fold; postflop made-hand strength via
the shared evaluator plus draw detection, betting strong hands, calling on
pot odds, folding weak to aggression; seeded randomness for mixing.

## Player protocol (`cosino.player.v1`)

JSON text frames on the Coworld player websocket. Player→game:
`{"type":"prompt","prompt":str}` (LLM policy) or
`{"type":"prompt","scripted":true}` (scripted baseline seat).
Game→player: `welcome` (seat alias, stacks, blinds), `state` after every
event batch (hole cards redacted to own seat), `final` with scores.
The published image carries two runnables: `/bin/cosino` (game) and
`/bin/cosino-player` (policy: `PLAYER_PROMPT` env, or `PLAYER_SCRIPTED=1`
for the scripted baseline).

## Sim module layout

- `src/cosino/types.nim` — GameConfig, events, seat state, JSON config update.
- `src/cosino/cards.nim` — cards as 0..51, seeded deck, 7-card evaluator
  (best-of-21 five-card ranks packed into a comparable int), pretty printing.
- `src/cosino/sim.nim` — `Hand` (betting state machine) and `Match`
  (hands loop, chip accounting, results), append-only `GameEvent` log,
  `replayMatch` re-deriving per-event states for scrubbing. Events carry
  amounts and stacks-after so replay never re-runs betting math.
- Event kinds: `handStart` (button, blinds), `deal` (per-seat, secret),
  `blind`, `say`, `action` (fold/check/call/bet/raise/allin with amount,
  stack and pot after), `board` (street cards), `reveal`, `award` (pot
  payouts per side pot), `handEnd`, `bust`.

## Episode budgeting

Parley's pattern: `EpisodeCallBudget` (~240 model calls) caps `hands` at
sample time using expected calls per hand (~2.5 × seats); the server also
plays inside `PlayBudgetFraction` of `COWORLD_TIMEOUT_SECONDS`, ending the
match between hands, so results and the replay always land.

## Viewers

`client/renderer.js`: shared canvas renderer — cog sprites around a felt
table, hole cards (backs for others until showdown), community cards, pot
and per-seat bet chips, dealer button, speech bubbles, action feed,
scorebug. Cards are drawn (rounded rects + rank/suit glyphs), no card art
assets. Global / player / replay HTML pages and the static wasm replay
viewer (`replay-viewer/cosino_replay.nim`) follow parley exactly; the wasm
module re-derives scrub states with the same sim code.

## Out of scope (v1)

Blind escalation, antes, rebuys, multi-table, per-seat time banks, separate
reaction chatter turns, tournament placement scoring.
