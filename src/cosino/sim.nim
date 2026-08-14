## Pure game rules for Cosino: no-limit Texas Hold'em. No IO, no networking,
## no LLM — the server, the tests, and the wasm replay viewer all drive this
## same module.
##
## A `Sim` is one hand: blinds, four betting streets, side pots, showdown.
## A `Match` is the episode: up to `config.hands` hands with the button
## rotating, stacks carried between hands, and no rebuys — a busted seat
## sits out. The score is the final chip share.
##
## Events are append-only and carry amounts, cards, and stacks-after, so
## replaying an event log is bookkeeping — the viewers never re-run the
## betting engine.

import std/[json, random, strutils], cards, types

export cards, types

const
  ## An episode's whole model-call allowance (one call per player action).
  ## A hosted episode is killed if it outlives the platform's artifact
  ## timeout, so the budget sits on the episode: `hands` is capped at
  ## sample time by the expected calls per hand at this seat count.
  EpisodeCallBudget* = 240
  MinHands* = 2
  MaxSeats* = 6
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 90_000

type
  PlayerAction* = object
    kind*: ActionKind
    amount*: int   ## bet size / raise-to street total; ignored otherwise

  Sim* = object
    ## One hand of hold'em.
    config*: GameConfig
    hand*: int             ## 0-based hand index in the match
    seats*: seq[Seat]
    button*: int
    sbSeat*: int
    bbSeat*: int
    board*: seq[int]
    street*: Street
    currentBet*: int       ## highest street commitment so far
    minRaiseSize*: int     ## smallest legal full-raise increment right now
    shortRaiseAccum: int   ## short all-in increments since the last full raise
    actingSeat*: int       ## seat to act; -1 once the hand is done
    pot*: int              ## chips committed this hand, all streets
    done*: bool
    deck: seq[int]         ## server-side only; replays carry cards in events
    dealIndex: int
    events*: seq[GameEvent]

  Match* = object
    ## A full episode: up to `config.hands` hands, stacks carried over.
    config*: GameConfig
    sim*: Sim              ## the hand in progress
    history: seq[GameEvent]
    handsPlayed*: int
    done*: bool

const CogNames* = [
  "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
  "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
]

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree. A policy name at the table leaks strategy
  ## ("that seat is the champion") straight into the LLMs' transcripts; the
  ## viewers map seats back to policy names for spectators.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the configured hand count into one episode's call budget: every
  ## player action is one model call, so the affordable hand count depends
  ## on the seat count. Idempotent: a config that already carries the cap
  ## (a replay being re-read) is returned untouched.
  result = config
  if result.sampled:
    return
  let seats = max(config.players.len, 2)
  ## Roughly: everyone acts once preflop and the shorthanded field acts a
  ## few more times across the later streets.
  let callsPerHand = max(2 * seats + 2, 6)
  result.hands = max(
    min(config.hands, EpisodeCallBudget div callsPerHand), MinHands)
  let plannedActions = max(result.hands * callsPerHand, 1)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div plannedActions)
  result.sampled = true

# ---- Seat and turn helpers --------------------------------------------------

proc inHand*(seat: Seat): bool =
  not seat.isOut and not seat.folded

proc liveCount*(sim: Sim): int =
  ## Seats still contesting the pot.
  for seat in sim.seats:
    if seat.inHand:
      inc result

proc needsAction(sim: Sim, index: int): bool =
  let seat = sim.seats[index]
  if not seat.inHand or seat.allIn:
    return false
  ## Chips owed always demand a response, even from the last seat with a
  ## live stack (fold or call the shove).
  if seat.committed < sim.currentBet:
    return true
  if seat.acted:
    return false
  ## A voluntary check or bet needs a live opponent who could respond;
  ## once everyone else is all-in the betting is simply over.
  for other in 0 ..< sim.seats.len:
    if other != index and sim.seats[other].inHand and
        not sim.seats[other].allIn:
      return true
  false

proc nextNeeding(sim: Sim, fromSeat: int): int =
  ## First seat clockwise strictly after `fromSeat` that still owes an
  ## action this street; -1 when the street is settled.
  let n = sim.seats.len
  for offset in 1 .. n:
    let index = (fromSeat + offset) mod n
    if sim.needsAction(index):
      return index
  -1

proc nextIn(sim: Sim, fromSeat: int): int =
  ## First seat clockwise strictly after `fromSeat` still in the hand.
  let n = sim.seats.len
  for offset in 1 .. n:
    let index = (fromSeat + offset) mod n
    if sim.seats[index].inHand:
      return index
  -1

proc callAmount*(sim: Sim, seat: int): int =
  ## Chips this seat must add to match the current bet (stack-capped).
  min(max(sim.currentBet - sim.seats[seat].committed, 0),
    sim.seats[seat].stack)

proc maxRaiseTo*(sim: Sim, seat: int): int =
  sim.seats[seat].committed + sim.seats[seat].stack

proc minRaiseTo*(sim: Sim, seat: int): int =
  ## Smallest legal raise-to total for this seat (its all-in if short).
  min(sim.currentBet + sim.minRaiseSize, sim.maxRaiseTo(seat))

proc minBet*(sim: Sim, seat: int): int =
  min(max(sim.config.bigBlind, 1), sim.seats[seat].stack)

proc canRaise*(sim: Sim, seat: int): bool =
  sim.seats[seat].mayRaise and sim.maxRaiseTo(seat) > sim.currentBet

# ---- Events -----------------------------------------------------------------

proc addEvent(
  sim: var Sim,
  kind: EventKind,
  seat: int,
  cards: seq[int] = @[],
  amount = 0,
  action = akFold,
  allIn = false,
  stackAfter = -1,
  betAfter = -1,
  potAfter = -1,
  text = ""
) =
  sim.events.add(GameEvent(
    kind: kind,
    hand: sim.hand,
    seat: seat,
    cards: cards,
    amount: amount,
    action: action,
    allIn: allIn,
    street: sim.street,
    stackAfter: stackAfter,
    betAfter: betAfter,
    potAfter: potAfter,
    text: text
  ))

# ---- Chip movement ----------------------------------------------------------

proc commit(sim: var Sim, index: int, chips: int): int =
  ## Moves up to `chips` from the seat's stack into the pot; returns the
  ## amount actually moved (the stack caps it — that is an all-in).
  result = min(chips, sim.seats[index].stack)
  sim.seats[index].stack -= result
  sim.seats[index].committed += result
  sim.seats[index].totalCommitted += result
  sim.pot += result
  if sim.seats[index].stack == 0 and not sim.seats[index].isOut:
    sim.seats[index].allIn = true

proc reopen(sim: var Sim, raiser: int) =
  ## A full raise re-opens the betting to everyone still able to act.
  for index in 0 ..< sim.seats.len:
    if index != raiser and sim.seats[index].inHand and
        not sim.seats[index].allIn:
      sim.seats[index].mayRaise = true

# ---- Hand resolution --------------------------------------------------------

proc dealNextStreet(sim: var Sim) =
  ## Advances to the next street and deals its community cards.
  for index in 0 ..< sim.seats.len:
    sim.seats[index].committed = 0
    sim.seats[index].acted = false
    if sim.seats[index].inHand and not sim.seats[index].allIn:
      sim.seats[index].mayRaise = true
  sim.currentBet = 0
  sim.minRaiseSize = sim.config.bigBlind
  sim.shortRaiseAccum = 0
  sim.street = succ(sim.street)
  let count = if sim.street == stFlop: 3 else: 1
  var dealt: seq[int]
  for _ in 1 .. count:
    dealt.add(sim.deck[sim.dealIndex])
    inc sim.dealIndex
  sim.board.add(dealt)
  sim.addEvent(evBoard, -1, cards = dealt, potAfter = sim.pot)

proc refundUncalled(sim: var Sim) =
  ## The chips nobody matched go back where they came from: the seat with
  ## the deepest commitment takes back everything above the second-deepest.
  ## Only a live seat can hold an uncalled bet — a folder forfeits its
  ## chips to the pot whatever it committed.
  var hiSeat = -1
  var hi = -1
  var second = -1
  for index, seat in sim.seats:
    if seat.totalCommitted > hi:
      second = hi
      hi = seat.totalCommitted
      hiSeat = index
    elif seat.totalCommitted > second:
      second = seat.totalCommitted
  if hiSeat < 0 or hi <= second or not sim.seats[hiSeat].inHand:
    return
  let refund = hi - second
  sim.seats[hiSeat].stack += refund
  sim.seats[hiSeat].totalCommitted -= refund
  sim.pot -= refund
  if sim.seats[hiSeat].allIn and sim.seats[hiSeat].stack > 0:
    sim.seats[hiSeat].allIn = false
  sim.addEvent(evAward, hiSeat, amount = refund,
    stackAfter = sim.seats[hiSeat].stack, potAfter = sim.pot,
    text = "returned")

proc resolveHand(sim: var Sim) =
  ## Refunds the uncalled excess, shows the called hands down, pays every
  ## pot (side pots from commitment levels), marks busts, ends the hand.
  sim.actingSeat = -1
  sim.refundUncalled()

  let contested = sim.liveCount() > 1
  var won = newSeq[bool](sim.seats.len)

  proc payout(sim: var Sim, winners: seq[int], slice: int, label: string) =
    ## Split evenly; odd chips go to the first winners clockwise from the
    ## button's left, one each.
    let share = slice div winners.len
    var odd = slice mod winners.len
    var ordered: seq[int]
    var probe = (sim.button + 1) mod sim.seats.len
    for _ in 0 ..< sim.seats.len:
      if probe in winners:
        ordered.add(probe)
      probe = (probe + 1) mod sim.seats.len
    for index in ordered:
      var chips = share
      if odd > 0:
        inc chips
        dec odd
      if chips == 0:
        continue
      sim.seats[index].stack += chips
      sim.pot -= chips
      won[index] = true
      sim.addEvent(evAward, index, amount = chips,
        stackAfter = sim.seats[index].stack, potAfter = sim.pot,
        text = label)

  if not contested:
    ## Everyone else folded: the last cog standing takes the whole pot,
    ## whatever anyone committed — side pots only exist at showdown.
    for index in 0 ..< sim.seats.len:
      if sim.seats[index].inHand:
        if sim.pot > 0:
          sim.payout(@[index], sim.pot, "main")
        break
  else:
    sim.street = stShowdown
    ## Reveal in clockwise order from the button's left.
    var ranks = newSeq[int](sim.seats.len)
    var seat = sim.nextIn(sim.button)
    for _ in 0 ..< sim.liveCount():
      let hole = sim.seats[seat].holeCards
      ranks[seat] = evalBest(hole & sim.board)
      sim.seats[seat].revealed = true
      sim.addEvent(evReveal, seat, cards = hole,
        text = describeRank(ranks[seat]))
      seat = sim.nextIn(seat)

    ## The live seats' commitment levels slice the pot: everyone pays into
    ## every level they reached, and each slice goes to the best hand among
    ## the live seats that reached it.
    var levels: seq[int]
    for seat in sim.seats:
      if seat.inHand and seat.totalCommitted > 0 and
          seat.totalCommitted notin levels:
        levels.add(seat.totalCommitted)
    for i in 0 ..< levels.len:
      for j in i + 1 ..< levels.len:
        if levels[j] < levels[i]:
          swap(levels[i], levels[j])

    var previous = 0
    var potIndex = 0
    var lastWinners: seq[int]
    for level in levels:
      var slice = 0
      for seat in sim.seats:
        slice += max(0, min(seat.totalCommitted, level) - previous)
      previous = level
      if slice == 0:
        continue
      var eligible: seq[int]
      for index, seat in sim.seats:
        if seat.inHand and seat.totalCommitted >= level:
          eligible.add(index)
      var winners: seq[int]
      var best = -1
      for index in eligible:
        if ranks[index] > best:
          best = ranks[index]
      for index in eligible:
        if ranks[index] == best:
          winners.add(index)
      lastWinners = winners
      sim.payout(winners, slice,
        if potIndex == 0: "main" else: "side " & $potIndex)
      inc potIndex
    ## Chips are the score, so none may evaporate: dead money committed
    ## beyond every live seat's level (a folder who outbet the table)
    ## sweeps to the deepest pot's winners.
    if sim.pot > 0 and lastWinners.len > 0:
      sim.payout(lastWinners, sim.pot, "sweep")

  for index in 0 ..< sim.seats.len:
    if won[index]:
      inc sim.seats[index].handsWon

  ## Busts: a seat that ends the hand with nothing sits out from here on.
  for index in 0 ..< sim.seats.len:
    if not sim.seats[index].isOut and sim.seats[index].stack == 0:
      sim.seats[index].isOut = true
      sim.addEvent(evBust, index)

  sim.addEvent(evHandEnd, -1, potAfter = 0)
  sim.done = true

proc progress(sim: var Sim, fromSeat: int) =
  ## After an action (or the blinds), picks the next actor — or closes the
  ## street, deals the next one (which runs the board out by itself when
  ## everyone is all-in), and resolves the hand.
  var origin = fromSeat
  while not sim.done:
    if sim.liveCount() <= 1:
      sim.resolveHand()
      return
    let next = sim.nextNeeding(origin)
    if next >= 0:
      sim.actingSeat = next
      return
    if sim.street == stRiver:
      sim.resolveHand()
      return
    sim.dealNextStreet()
    origin = sim.button

# ---- Hand setup -------------------------------------------------------------

proc initHand*(
  config: GameConfig,
  hand: int,
  button: int,
  stacks: seq[int],
  handsWon: seq[int],
  names: seq[string],
  deck: seq[int] = @[]
): Sim =
  ## Deals one hand: blinds up, hole cards out, preflop action ready.
  ## `stacks` carries the chip counts into the hand; a zero stack sits out.
  ## A non-empty `deck` overrides the seeded shuffle (tests and fixtures):
  ## hole cards go out two at a time clockwise from the small blind, then
  ## the flop, turn, and river in order.
  if config.players.len < 2 or config.players.len > MaxSeats:
    raise newException(CosinoError,
      "cosino needs 2.." & $MaxSeats & " players")
  result = Sim(config: config, hand: hand, button: button,
    street: stPreflop, actingSeat: -1)
  var active = 0
  for index in 0 ..< config.players.len:
    result.seats.add(Seat(
      name: names[index],
      stack: stacks[index],
      isOut: stacks[index] <= 0,
      handsWon: handsWon[index],
      mayRaise: stacks[index] > 0
    ))
    if stacks[index] > 0:
      inc active
  if active < 2:
    raise newException(CosinoError, "a hand needs two funded seats")
  if result.seats[button].isOut:
    raise newException(CosinoError, "the button must be a funded seat")

  ## The deck draws from the seed and hand index, so a pinned seed
  ## reproduces the whole episode.
  if deck.len > 0:
    result.deck = deck
  else:
    var rng = initRand(int64(config.seed) * 104729 + int64(hand) * 7919 + 13)
    result.deck = shuffledDeck(rng)

  result.addEvent(evHandStart, button,
    amount = config.bigBlind, potAfter = 0,
    text = $config.smallBlind & "/" & $config.bigBlind)

  ## Heads-up, the button posts the small blind and acts first preflop;
  ## multiway, the blinds sit clockwise from the button.
  if active == 2:
    result.sbSeat = button
    result.bbSeat = result.nextIn(button)
  else:
    result.sbSeat = result.nextIn(button)
    result.bbSeat = result.nextIn(result.sbSeat)

  ## Hole cards, clockwise from the small blind.
  var seat = result.sbSeat
  for _ in 0 ..< active:
    var hole = @[result.deck[result.dealIndex],
      result.deck[result.dealIndex + 1]]
    result.dealIndex += 2
    result.seats[seat].holeCards = hole
    result.addEvent(evDeal, seat, cards = hole)
    seat = result.nextIn(seat)

  for (blindSeat, blind, label) in [
    (result.sbSeat, config.smallBlind, "small"),
    (result.bbSeat, config.bigBlind, "big")
  ]:
    let posted = result.commit(blindSeat, blind)
    result.addEvent(evBlind, blindSeat, amount = posted,
      allIn = result.seats[blindSeat].allIn,
      stackAfter = result.seats[blindSeat].stack,
      betAfter = result.seats[blindSeat].committed,
      potAfter = result.pot, text = label)

  ## The big blind is the bet to beat even when its poster was short.
  result.currentBet = config.bigBlind
  result.minRaiseSize = config.bigBlind
  result.progress(result.bbSeat)

# ---- Player actions ---------------------------------------------------------

proc recordSay*(sim: var Sim, seat: int, text: string) =
  if text.len == 0:
    return
  sim.addEvent(evSay, seat, text = text)

proc applyAction*(sim: var Sim, seat: int, act: PlayerAction) =
  ## One player action. Raises CosinoError on anything illegal; the caller
  ## (game server) falls back to the scripted baseline on a rejection.
  if sim.done:
    raise newException(CosinoError, "the hand is over")
  if seat != sim.actingSeat:
    raise newException(CosinoError, "not this seat's turn")

  case act.kind
  of akFold:
    sim.seats[seat].folded = true
    sim.addEvent(evAction, seat, action = akFold,
      stackAfter = sim.seats[seat].stack,
      betAfter = sim.seats[seat].committed, potAfter = sim.pot)
  of akCheck:
    if sim.seats[seat].committed < sim.currentBet:
      raise newException(CosinoError, "cannot check facing a bet")
    sim.addEvent(evAction, seat, action = akCheck,
      stackAfter = sim.seats[seat].stack,
      betAfter = sim.seats[seat].committed, potAfter = sim.pot)
  of akCall:
    let owed = sim.callAmount(seat)
    if owed <= 0:
      raise newException(CosinoError, "nothing to call — check instead")
    let paid = sim.commit(seat, owed)
    sim.addEvent(evAction, seat, action = akCall, amount = paid,
      allIn = sim.seats[seat].allIn,
      stackAfter = sim.seats[seat].stack,
      betAfter = sim.seats[seat].committed, potAfter = sim.pot)
  of akBet:
    if sim.currentBet > 0:
      raise newException(CosinoError, "facing a bet — raise instead")
    let target = act.amount
    let ceiling = sim.maxRaiseTo(seat)
    if target <= 0 or target > ceiling:
      raise newException(CosinoError, "bet must be between 1 and the stack")
    if target < sim.minBet(sim.actingSeat) and target < ceiling:
      raise newException(CosinoError,
        "bet below the minimum (" & $sim.minBet(seat) & ")")
    discard sim.commit(seat, target - sim.seats[seat].committed)
    sim.currentBet = target
    sim.minRaiseSize = target
    sim.shortRaiseAccum = 0
    sim.reopen(seat)
    sim.addEvent(evAction, seat, action = akBet, amount = target,
      allIn = sim.seats[seat].allIn,
      stackAfter = sim.seats[seat].stack,
      betAfter = sim.seats[seat].committed, potAfter = sim.pot)
  of akRaise:
    if sim.currentBet == 0:
      raise newException(CosinoError, "nothing to raise — bet instead")
    if not sim.seats[seat].mayRaise:
      raise newException(CosinoError,
        "betting is closed to this seat this street")
    let ceiling = sim.maxRaiseTo(seat)
    if act.amount <= sim.currentBet:
      raise newException(CosinoError, "a raise must exceed the current bet")
    if act.amount > ceiling:
      raise newException(CosinoError, "cannot raise beyond the stack")
    let increment = act.amount - sim.currentBet
    let full = increment >= sim.minRaiseSize
    if act.amount < ceiling and not full:
      raise newException(CosinoError,
        "raise below the minimum (to " & $sim.minRaiseTo(seat) & ")")
    discard sim.commit(seat, act.amount - sim.seats[seat].committed)
    sim.currentBet = act.amount
    if full:
      sim.minRaiseSize = increment
      sim.shortRaiseAccum = 0
      sim.reopen(seat)
    else:
      ## A short all-in does not re-open the betting — unless short raises
      ## stack up to a full raise between them.
      sim.shortRaiseAccum += increment
      if sim.shortRaiseAccum >= sim.minRaiseSize:
        sim.shortRaiseAccum = 0
        sim.reopen(seat)
    sim.addEvent(evAction, seat, action = akRaise, amount = act.amount,
      allIn = sim.seats[seat].allIn,
      stackAfter = sim.seats[seat].stack,
      betAfter = sim.seats[seat].committed, potAfter = sim.pot)

  sim.seats[seat].acted = true
  sim.seats[seat].mayRaise = false
  sim.progress(seat)

# ---- Match ------------------------------------------------------------------

proc totalChips*(config: GameConfig): int =
  config.players.len * config.startingStack

proc initMatch*(config: GameConfig): Match =
  if config.players.len < 2 or config.players.len > MaxSeats:
    raise newException(CosinoError,
      "cosino needs 2.." & $MaxSeats & " players")
  let names = tableNames(config.players, config.seed)
  var stacks = newSeq[int](config.players.len)
  var handsWon = newSeq[int](config.players.len)
  for index in 0 ..< stacks.len:
    stacks[index] = config.startingStack
  let button = ((config.seed mod config.players.len) +
    config.players.len) mod config.players.len
  Match(
    config: config,
    sim: initHand(config, 0, button, stacks, handsWon, names)
  )

proc allEvents*(match: Match): seq[GameEvent] =
  match.history & match.sim.events

proc stacks*(match: Match): seq[int] =
  for seat in match.sim.seats:
    result.add(seat.stack)

proc fundedSeats(match: Match): int =
  for seat in match.sim.seats:
    if seat.stack > 0:
      inc result

proc finishHand*(match: var Match) =
  ## Accounts the finished hand and ends the match at the hand limit or
  ## when fewer than two seats can still post. Deliberately does NOT deal
  ## the next hand — call `nextHand` for that — so the caller can stop the
  ## match between hands (episode deadline) without a dealt-but-unplayed
  ## hand corrupting the final stacks.
  if not match.sim.done or match.done:
    raise newException(CosinoError, "no finished hand to fold in")
  inc match.handsPlayed
  if match.handsPlayed >= match.config.hands or match.fundedSeats() < 2:
    match.done = true

proc nextHand*(match: var Match) =
  ## Deals the next hand of a live match.
  if match.done or not match.sim.done:
    raise newException(CosinoError, "the match is over or a hand is live")
  var stacks: seq[int]
  var handsWon: seq[int]
  var names: seq[string]
  for seat in match.sim.seats:
    stacks.add(seat.stack)
    handsWon.add(seat.handsWon)
    names.add(seat.name)
  ## The button walks clockwise to the next funded seat.
  var button = (match.sim.button + 1) mod stacks.len
  while stacks[button] <= 0:
    button = (button + 1) mod stacks.len
  match.history.add(match.sim.events)
  match.sim = initHand(match.config, match.sim.hand + 1, button, stacks,
    handsWon, names)

proc endMatchEarly*(match: var Match) =
  ## Stop after the hand just scored. The hosted platform kills an episode
  ## that outlives its timeout and keeps NOTHING — no results, no replay —
  ## so a short honest match always beats a long one that never lands.
  match.done = true

proc matchWinners*(match: Match): seq[bool] =
  result = newSeq[bool](match.sim.seats.len)
  var best = -1
  for seat in match.sim.seats:
    if seat.stack > best:
      best = seat.stack
  for index, seat in match.sim.seats:
    result[index] = seat.stack == best

proc resultsJson*(match: Match): JsonNode =
  let winFlags = match.matchWinners()
  let chips = match.config.totalChips()
  var names = newJArray()
  var scoresNode = newJArray()
  var winNode = newJArray()
  var stacksNode = newJArray()
  var handsWonNode = newJArray()
  var bustedNode = newJArray()
  for index, seat in match.sim.seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%match.config.players[index].name)
    ## The chip share IS the score: in [0,1], summing to 1 across seats,
    ## comparable between episodes whatever the seat count.
    scoresNode.add(%(seat.stack / chips))
    winNode.add(%(match.done and winFlags[index]))
    stacksNode.add(%seat.stack)
    handsWonNode.add(%seat.handsWon)
    bustedNode.add(%seat.isOut)
  %*{
    "names": names,
    "scores": scoresNode,
    "win": winNode,
    "stacks": stacksNode,
    "handsWon": handsWonNode,
    "busted": bustedNode,
    "handsPlayed": match.handsPlayed,
    "hands": match.config.hands,
    "startingStack": match.config.startingStack,
    "smallBlind": match.config.smallBlind,
    "bigBlind": match.config.bigBlind
  }

# ---- Viewer state -----------------------------------------------------------

proc seatStates*(sim: Sim): JsonNode =
  ## The seat panel every viewer draws. Hole cards ride along in full; the
  ## server redacts them per player socket, spectators keep everything.
  result = newJArray()
  for index, seat in sim.seats:
    var cardsNode = newJArray()
    for card in seat.holeCards:
      cardsNode.add(%card)
    result.add(%*{
      "name": seat.name,
      "stack": seat.stack,
      "bet": seat.committed,
      "cards": cardsNode,
      "revealed": seat.revealed,
      "folded": seat.folded,
      "allIn": seat.allIn,
      "out": seat.isOut,
      "acting": index == sim.actingSeat,
      "handsWon": seat.handsWon
    })

proc tableStateJson*(sim: Sim): JsonNode =
  var boardNode = newJArray()
  for card in sim.board:
    boardNode.add(%card)
  %*{
    "seats": sim.seatStates(),
    "board": boardNode,
    "pot": sim.pot,
    "street": $sim.street,
    "hand": sim.hand,
    "button": sim.button,
    "currentBet": sim.currentBet,
    "handDone": sim.done
  }

# ---- Replay -----------------------------------------------------------------

type
  ReplayFrame* = object
    ## One scrub position: the reconstructed table state after an event
    ## prefix (frames[i] = state after events[0..<i]).
    seats*: seq[Seat]
    board*: seq[int]
    pot*: int
    street*: Street
    hand*: int
    button*: int
    acting*: int      ## seat about to act (the next event's actor), or -1
    handDone*: bool

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[ReplayFrame] =
  ## Re-derives the state timeline from a recorded event log. Events carry
  ## amounts and stacks-after, so this never re-runs the betting engine.
  let n = config.players.len
  var frame = ReplayFrame(
    street: stPreflop,
    acting: -1,
    button: -1
  )
  for index in 0 ..< n:
    frame.seats.add(Seat(
      name: "Seat " & $(index + 1),
      stack: config.startingStack
    ))
  result.add(frame)
  for at, event in events:
    case event.kind
    of evHandStart:
      frame.hand = event.hand
      frame.button = event.seat
      frame.board = @[]
      frame.pot = 0
      frame.street = stPreflop
      frame.handDone = false
      for index in 0 ..< n:
        frame.seats[index].committed = 0
        frame.seats[index].totalCommitted = 0
        frame.seats[index].folded = false
        frame.seats[index].allIn = false
        frame.seats[index].holeCards = @[]
        frame.seats[index].revealed = false
    of evDeal:
      frame.seats[event.seat].holeCards = event.cards
    of evBlind, evAction:
      if event.kind == evAction and event.action == akFold:
        frame.seats[event.seat].folded = true
      ## `amount` is the raise-to total for bets and raises, so the chips
      ## actually moved are the change in the street commitment.
      frame.seats[event.seat].totalCommitted +=
        max(event.betAfter - frame.seats[event.seat].committed, 0)
      frame.seats[event.seat].stack = event.stackAfter
      frame.seats[event.seat].committed = event.betAfter
      frame.seats[event.seat].allIn = event.allIn
      frame.pot = event.potAfter
      frame.street = event.street
    of evSay:
      discard
    of evBoard:
      frame.board.add(event.cards)
      frame.street = event.street
      for index in 0 ..< n:
        frame.seats[index].committed = 0
    of evReveal:
      frame.seats[event.seat].holeCards = event.cards
      frame.seats[event.seat].revealed = true
      frame.street = event.street
    of evAward:
      frame.seats[event.seat].stack = event.stackAfter
      frame.pot = event.potAfter
      if event.text != "returned":
        frame.street = event.street
    of evBust:
      frame.seats[event.seat].isOut = true
    of evHandEnd:
      frame.pot = 0
      frame.handDone = true
    ## Who is about to act: the actor of the next action event, if the very
    ## next event is one.
    frame.acting =
      if at + 1 < events.len and events[at + 1].kind == evAction:
        events[at + 1].seat
      else:
        -1
    result.add(frame)

proc frameStateJson*(frame: ReplayFrame): JsonNode =
  ## Same shape as tableStateJson, derived from a replay frame.
  var seatsNode = newJArray()
  for index, seat in frame.seats:
    var cardsNode = newJArray()
    for card in seat.holeCards:
      cardsNode.add(%card)
    seatsNode.add(%*{
      "name": seat.name,
      "stack": seat.stack,
      "bet": seat.committed,
      "cards": cardsNode,
      "revealed": seat.revealed,
      "folded": seat.folded,
      "allIn": seat.allIn,
      "out": seat.isOut,
      "acting": index == frame.acting,
      "handsWon": seat.handsWon
    })
  var boardNode = newJArray()
  for card in frame.board:
    boardNode.add(%card)
  %*{
    "seats": seatsNode,
    "board": boardNode,
    "pot": frame.pot,
    "street": $frame.street,
    "hand": frame.hand,
    "button": frame.button,
    "handDone": frame.handDone
  }

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{
    "kind": $event.kind,
    "hand": event.hand,
    "seat": event.seat,
    "street": $event.street
  }
  if event.cards.len > 0:
    var cardsNode = newJArray()
    for card in event.cards:
      cardsNode.add(%card)
    result["cards"] = cardsNode
  if event.amount != 0:
    result["amount"] = %event.amount
  if event.kind == evAction:
    result["action"] = %($event.action)
  if event.allIn:
    result["allIn"] = %true
  if event.stackAfter >= 0:
    result["stackAfter"] = %event.stackAfter
  if event.betAfter >= 0:
    result["betAfter"] = %event.betAfter
  if event.potAfter >= 0:
    result["potAfter"] = %event.potAfter
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    hand: node{"hand"}.getInt(0),
    seat: node{"seat"}.getInt(-1),
    amount: node{"amount"}.getInt(0),
    allIn: node{"allIn"}.getBool(false),
    street: parseEnum[Street](node{"street"}.getStr("preflop")),
    stackAfter: node{"stackAfter"}.getInt(-1),
    betAfter: node{"betAfter"}.getInt(-1),
    potAfter: node{"potAfter"}.getInt(-1),
    text: node{"text"}.getStr("")
  )
  if node.hasKey("cards"):
    for card in node["cards"]:
      result.cards.add(card.getInt())
  if node.hasKey("action"):
    result.action = parseEnum[ActionKind](node["action"].getStr())
