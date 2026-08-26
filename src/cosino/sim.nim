## Pure game rules for Cosino: Kuhn, Leduc and no-limit Texas Hold'em
## behind one `Variant`. No IO, no networking, no LLM — the server, the
## tests, and the wasm replay viewer all drive this same module.
##
## A `Sim` is one hand. A `Match` is the episode. On the LADDER rungs every
## hand starts from `startingStack` chips at every seat (there are no busts
## and no carried stacks — duplicate scoring needs both halves of a pair to
## start identical, and the collusion audit needs every seat live all the way
## through) and a seat's result is its cumulative NET chips. On the chip-race
## TABLE (`config.chipRace`) stacks carry between hands, the button walks to
## the next funded seat, a busted seat sits out for good, and the final chip
## share is the score.
##
## Events are append-only and carry amounts, cards and stacks-after, so
## replaying an event log is bookkeeping: the viewers never re-run the betting
## engine. The wall-clock stop is itself a recorded event (`matchEnd`), so a
## `deadline` replay re-derives bit-identically to a `complete` one.

import std/[json, math, random, strutils], audit, cards, solve, types

export audit, cards, solve, types

const
  ## An episode's whole model-call allowance (one call per decision). Poker is
  ## SEQUENTIAL: one seat is on decision at a time, so the budget is per
  ## decision, not per turn. 220 x 3.0 s = 660 s, exactly the soft guard.
  EpisodeDecisionBudget* = 220
  MinHands* = 2
  GameVersion* = 1
  ## Share of the platform's episode timeout spent playing, and the hard stop.
  ## The 60% bound is on the TRUE worst-case settle, and the hard guard is
  ## checked BEFORE a decision: a decision admitted just under the threshold
  ## still runs to completion. So the threshold nets one worst-case decision
  ## off 60% -- 2.1 s spacing floor + two 20 s LLM attempts + the turn delay
  ## and the settle write, ~45 s -- and the hard stop is 0.56 (672 s of
  ## 1200 s), which settles by 720 s = 60%. The soft stop sits a pair
  ## boundary's worth of play below it at 0.55 (660 s).
  PlayBudgetFraction* = 0.55
  HardDeadlineFraction* = 0.56
  ## The game container is NOT given COWORLD_TIMEOUT_SECONDS; assume this.
  DefaultEpisodeTimeoutSeconds* = 1200.0
  ## Inter-decision wall spacing floor (the Bedrock sidecar caps an episode at
  ## 30 requests/minute).
  DecisionSpacingMs* = 2100

type
  PlayerAction* = object
    kind*: ActionKind
    amount*: int   ## bet size / raise-to street total; ignored otherwise

  Sim* = object
    ## One hand.
    config*: GameConfig
    hand*: int             ## 0-based hand index in the match
    pair*: int             ## duplicate pair index (hand div 2)
    mirror*: bool          ## the mirror half of the pair
    seats*: seq[Seat]      ## indexed by SLOT
    order*: seq[int]       ## slot sitting at each table position
    posOf*: seq[int]       ## table position of each slot
    button*: int           ## slot at position 0
    sbSeat*: int
    bbSeat*: int
    board*: seq[int]
    street*: Street
    round*: int            ## 0-based betting round
    wagers*: int           ## wagers made this round (fixed-limit rungs)
    currentBet*: int       ## highest street commitment so far
    minRaiseSize*: int     ## smallest legal full-raise increment right now
    shortRaiseAccum: int   ## short all-in increments since the last full raise
    actingSeat*: int       ## seat to act; -1 once the hand is done
    pot*: int              ## chips committed this hand, all streets
    done*: bool
    voided*: bool          ## abandoned by the hard deadline; not scored
    deck: seq[int]         ## server-side only; replays carry cards in events
    dealIndex: int
    events*: seq[GameEvent]

  Match* = object
    ## A full episode.
    config*: GameConfig
    sim*: Sim              ## the hand in progress
    history: seq[GameEvent]
    names*: seq[string]
    handsPlayed*: int      ## hands dealt and finished, voided ones included
    handsScored*: int      ## hands whose chips counted
    net*: seq[int]         ## cumulative net chips by slot
    handsWon*: seq[int]
    stackOffs*: seq[int]
    done*: bool
    ended*: bool           ## the tail (calib/audit/matchEnd) is recorded
    reason*: EndReason

const CogNames* = [
  "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
  "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
]

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog alias, drawn deterministically from the seed so replays and
  ## the live table agree. The viewers map seats back to policy names for
  ## spectators.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(truncateRunes(pool[index], MaxAliasLen))
    else:
      result.add(truncateRunes("Cog " & $(index + 1), MaxAliasLen))

proc expectedDecisionTenths*(config: GameConfig): int =
  ## Expected decisions per hand, in tenths, per the design's budget table.
  case config.variant
  of vKuhn: 26
  of vLeduc: 54
  of vHoldem: (if config.players.len <= 2: 60 else: 130)

proc handCap*(config: GameConfig): int =
  (EpisodeDecisionBudget * 10) div config.expectedDecisionTenths()

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the configured hand count into the episode's decision budget and
  ## rounds DOWN to an even number so every duplicate pair is complete.
  ## Idempotent: a config that already carries the cap (a replay being
  ## re-read) is returned untouched.
  result = config
  if result.sampled:
    return
  var hands = min(config.hands, config.handCap())
  if config.duplicate:
    hands = hands - (hands mod 2)
  result.hands = max(hands, MinHands)
  result.sampled = true

proc seatOrderFor*(config: GameConfig): seq[int] =
  ## Seed-derived permutation: `result[p]` is the slot sitting at table
  ## position `p`. A colluding pair cannot count on a fixed relative position.
  let n = config.players.len
  result = newSeq[int](n)
  for index in 0 ..< n:
    result[index] = index
  if config.randomiseSeating:
    var rng = initRand(int64(config.seed) * 7907 + 101)
    rng.shuffle(result)

proc positionsFor*(config: GameConfig, hand: int): seq[int] =
  ## The position map for a hand. The mirror half of a duplicate pair rotates
  ## the whole table by half a table, so each seat plays its counterpart's
  ## cards from its counterpart's position.
  let n = config.players.len
  let order =
    if config.seatOrder.len == n: config.seatOrder
    else: config.seatOrderFor()
  let mirror = config.duplicate and (hand mod 2 == 1)
  result = newSeq[int](n)
  for position in 0 ..< n:
    result[position] =
      if mirror: order[(position + n div 2) mod n]
      else: order[position]

proc pairDeck*(config: GameConfig, pair: int): seq[int] =
  ## Both hands of a pair are dealt from this one shuffle.
  var rng = initRand(int64(config.seed) * 104729 + int64(pair) * 7919 + 13)
  case config.variant
  of vKuhn:
    result = kuhnDeck()
    rng.shuffle(result)
  of vLeduc:
    result = leducDeck()
    rng.shuffle(result)
  of vHoldem:
    result = shuffledDeck(rng)

# ---- Seat and turn helpers --------------------------------------------------

proc inHand*(seat: Seat): bool =
  not seat.isOut and not seat.folded

proc liveCount*(sim: Sim): int =
  for seat in sim.seats:
    if seat.inHand:
      inc result

proc needsAction(sim: Sim, index: int): bool =
  let seat = sim.seats[index]
  if not seat.inHand or seat.allIn:
    return false
  ## Chips owed always demand a response, even from the last seat with a live
  ## stack (fold or call the shove).
  if seat.committed < sim.currentBet:
    return true
  if seat.acted:
    return false
  ## A voluntary check or bet needs a live opponent who could respond; once
  ## everyone else is all-in the betting is simply over.
  for other in 0 ..< sim.seats.len:
    if other != index and sim.seats[other].inHand and
        not sim.seats[other].allIn:
      return true
  false

proc nextNeeding(sim: Sim, fromSeat: int): int =
  ## First seat clockwise (in TABLE POSITION order) strictly after `fromSeat`
  ## that still owes an action this street; -1 when the street is settled.
  let n = sim.seats.len
  let from0 = sim.posOf[fromSeat]
  for offset in 1 .. n:
    let index = sim.order[(from0 + offset) mod n]
    if sim.needsAction(index):
      return index
  -1

proc nextIn*(sim: Sim, fromSeat: int): int =
  ## First seat clockwise strictly after `fromSeat` still in the hand.
  let n = sim.seats.len
  let from0 = sim.posOf[fromSeat]
  for offset in 1 .. n:
    let index = sim.order[(from0 + offset) mod n]
    if sim.seats[index].inHand:
      return index
  -1

proc wagerSize*(sim: Sim): int =
  sim.config.variant.betSizes(sim.config.bigBlind)[min(sim.round, 1)]

proc callAmount*(sim: Sim, seat: int): int =
  min(max(sim.currentBet - sim.seats[seat].committed, 0),
    sim.seats[seat].stack)

proc maxRaiseTo*(sim: Sim, seat: int): int =
  sim.seats[seat].committed + sim.seats[seat].stack

proc minBet*(sim: Sim, seat: int): int =
  if sim.config.variant.fixedLimit:
    min(sim.wagerSize(), sim.seats[seat].stack)
  else:
    min(max(sim.config.bigBlind, 1), sim.seats[seat].stack)

proc minRaiseTo*(sim: Sim, seat: int): int =
  ## Smallest legal raise-to total for this seat (its all-in if short).
  if sim.config.variant.fixedLimit:
    min(sim.currentBet + sim.wagerSize(), sim.maxRaiseTo(seat))
  else:
    min(sim.currentBet + sim.minRaiseSize, sim.maxRaiseTo(seat))

proc wagerCapReached*(sim: Sim): bool =
  sim.config.variant.fixedLimit and
    sim.wagers >= sim.config.variant.maxWagers()

proc canRaise*(sim: Sim, seat: int): bool =
  if sim.wagerCapReached():
    return false
  sim.seats[seat].mayRaise and sim.maxRaiseTo(seat) > sim.currentBet

proc canBet*(sim: Sim, seat: int): bool =
  sim.currentBet == 0 and not sim.wagerCapReached() and
    sim.maxRaiseTo(seat) > 0

proc oddChipFirst*(sim: Sim): int =
  ## Where an odd chip goes: position 0 (the button) on the calibration rungs,
  ## clockwise from the button's left at Hold'em.
  if sim.config.variant.fixedLimit: sim.order[0]
  else: sim.order[1 mod sim.seats.len]

# ---- Events -----------------------------------------------------------------

proc addEvent(
  sim: var Sim,
  kind: EventKind,
  seat: int,
  cards: seq[int] = @[],
  best: seq[int] = @[],
  amount = 0,
  action = akFold,
  allIn = false,
  stackAfter = -1,
  betAfter = -1,
  potAfter = -1,
  pair = -1,
  mirror = false,
  text = "",
  data: JsonNode = nil
) =
  sim.events.add(GameEvent(
    kind: kind,
    hand: sim.hand,
    seat: seat,
    cards: cards,
    best: best,
    amount: amount,
    action: action,
    allIn: allIn,
    street: sim.street,
    stackAfter: stackAfter,
    betAfter: betAfter,
    potAfter: potAfter,
    pair: pair,
    mirror: mirror,
    text: text,
    data: data
  ))

# ---- Chip movement ----------------------------------------------------------

proc commit(sim: var Sim, index: int, chips: int): int =
  ## Moves up to `chips` from the seat's stack into the pot; returns the amount
  ## actually moved (the stack caps it — that is an all-in).
  result = min(chips, sim.seats[index].stack)
  sim.seats[index].stack -= result
  sim.seats[index].committed += result
  sim.seats[index].totalCommitted += result
  sim.pot += result
  if sim.seats[index].stack == 0:
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
  sim.wagers = 0
  inc sim.round
  sim.street = succ(sim.street)
  let count =
    if sim.config.variant == vHoldem and sim.street == stFlop: 3 else: 1
  var dealt: seq[int]
  for _ in 1 .. count:
    dealt.add(sim.deck[sim.dealIndex])
    inc sim.dealIndex
  sim.board.add(dealt)
  sim.addEvent(evBoard, -1, cards = dealt, potAfter = sim.pot)

proc refundUncalled(sim: var Sim) =
  ## The chips nobody matched go back where they came from: the seat with the
  ## deepest commitment takes back everything above the second-deepest. Only a
  ## live seat can hold an uncalled bet.
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

proc showdownRank*(sim: Sim, seat: int): int =
  ## Comparable hand strength for this variant.
  let hole = sim.seats[seat].holeCards
  case sim.config.variant
  of vKuhn:
    1000 + hole[0].rank
  of vLeduc:
    leducRank(hole[0], if sim.board.len > 0: sim.board[0] else: -1)
  of vHoldem:
    evalBest(hole & sim.board)

proc describeShowdown*(variant: Variant, packed: int, hole: seq[int],
    board: seq[int]): string =
  case variant
  of vKuhn, vLeduc:
    const Names = ["deuce", "three", "four", "five", "six", "seven", "eight",
      "nine", "ten", "jack", "queen", "king", "ace"]
    const Plural = ["deuces", "threes", "fours", "fives", "sixes", "sevens",
      "eights", "nines", "tens", "jacks", "queens", "kings", "aces"]
    let value = hole[0].rank
    if packed >= 2000: "a pair of " & Plural[value]
    else: Names[value] & " high"
  of vHoldem:
    describeRank(packed)

proc showdownBest*(sim: Sim, seat: int): seq[int] =
  let hole = sim.seats[seat].holeCards
  case sim.config.variant
  of vKuhn: hole
  of vLeduc: hole & sim.board
  of vHoldem: bestFive(hole & sim.board).five

proc resolveHand(sim: var Sim) =
  ## Refunds the uncalled excess, shows the called hands down, pays every pot
  ## (side pots from commitment levels), records stack-offs, ends the hand.
  sim.actingSeat = -1
  sim.refundUncalled()

  let contested = sim.liveCount() > 1
  var won = newSeq[bool](sim.seats.len)

  proc payout(sim: var Sim, winners: seq[int], slice: int, label: string) =
    ## Split evenly; odd chips go to the first winners from `oddChipFirst`.
    let share = slice div winners.len
    var odd = slice mod winners.len
    var ordered: seq[int]
    var probe = sim.posOf[sim.oddChipFirst()]
    for _ in 0 ..< sim.seats.len:
      let slot = sim.order[probe]
      if slot in winners:
        ordered.add(slot)
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
    ## Everyone else folded: the last cog standing takes the whole pot.
    for index in 0 ..< sim.seats.len:
      if sim.seats[index].inHand:
        if sim.pot > 0:
          sim.payout(@[index], sim.pot, "main")
        break
  else:
    sim.street = stShowdown
    var ranks = newSeq[int](sim.seats.len)
    var seat = sim.nextIn(sim.button)
    if sim.seats[sim.button].inHand:
      seat = sim.button
    var revealed = 0
    let live = sim.liveCount()
    while revealed < live:
      let packed = sim.showdownRank(seat)
      ranks[seat] = packed
      sim.seats[seat].revealed = true
      sim.addEvent(evReveal, seat, cards = sim.seats[seat].holeCards,
        best = sim.showdownBest(seat),
        text = describeShowdown(sim.config.variant, packed,
          sim.seats[seat].holeCards, sim.board))
      inc revealed
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
    ## Chips are the score, so none may evaporate: dead money committed beyond
    ## every live seat's level sweeps to the deepest pot's winners.
    if sim.pot > 0 and lastWinners.len > 0:
      sim.payout(lastWinners, sim.pot, "sweep")

  for index in 0 ..< sim.seats.len:
    if won[index]:
      inc sim.seats[index].handsWon

  if sim.config.chipRace:
    ## Busts are final: a seat that ends the hand with nothing sits out.
    for index in 0 ..< sim.seats.len:
      if not sim.seats[index].isOut and sim.seats[index].stack == 0:
        sim.seats[index].isOut = true
        sim.addEvent(evBust, index)
  elif sim.config.variant == vHoldem:
    ## Cosmetic only: stacks reset next hand, nobody is ever removed.
    for index in 0 ..< sim.seats.len:
      if sim.seats[index].stack == 0:
        sim.addEvent(evStackOff, index)

  var netNode = newJArray()
  for index, seat in sim.seats:
    ## On the chip race `seat.net` is the carried stack minus the buy-in, so
    ## the hand's own swing is already inside `seat.stack`.
    netNode.add(%(
      if sim.config.chipRace: seat.stack - sim.config.startingStack
      else: seat.net + seat.stack - sim.config.startingStack))
  sim.addEvent(evHandEnd, -1, potAfter = 0, data = %*{"net": netNode})
  sim.done = true

proc progress(sim: var Sim, fromSeat: int) =
  ## After an action (or the blinds/antes), picks the next actor — or closes
  ## the street, deals the next one, and resolves the hand.
  var origin = fromSeat
  while not sim.done:
    if sim.liveCount() <= 1:
      sim.resolveHand()
      return
    let next = sim.nextNeeding(origin)
    if next >= 0:
      sim.actingSeat = next
      return
    if sim.street == sim.config.variant.lastStreet():
      sim.resolveHand()
      return
    sim.dealNextStreet()
    ## OpenSpiel's Kuhn/Leduc do not switch the first actor between rounds:
    ## position 0 acts first every round. Hold'em opens left of the button.
    origin =
      if sim.config.variant.fixedLimit: sim.order[sim.seats.len - 1]
      else: sim.button

# ---- Hand setup -------------------------------------------------------------

proc initHand*(
  config: GameConfig,
  hand: int,
  names: seq[string],
  handsWon: seq[int],
  net: seq[int],
  deck: seq[int] = @[],
  stacks: seq[int] = @[],
  button = -1
): Sim =
  ## Deals one hand. On the ladder EVERY seat starts on `startingStack` —
  ## there are no busts and no carried chips. On the chip race the caller
  ## passes `stacks` (a zero stack sits out) and the `button` slot, and the
  ## table ring is the seat order rotated so the button holds position 0.
  ## A non-empty `deck` overrides the pair shuffle.
  let n = config.players.len
  if n < 2 or n > MaxSeats:
    raise newException(CosinoError, "cosino needs 2.." & $MaxSeats & " players")
  result = Sim(config: config, hand: hand, street: stPreflop, actingSeat: -1)
  result.pair = if config.duplicate: hand div 2 else: hand
  result.mirror = config.duplicate and (hand mod 2 == 1)
  if config.chipRace:
    if stacks.len != n:
      raise newException(CosinoError, "the chip race needs a stack per seat")
    let ring =
      if config.seatOrder.len == n: config.seatOrder
      else: config.seatOrderFor()
    var at = -1
    for position, slot in ring:
      if slot == button:
        at = position
    if at < 0:
      raise newException(CosinoError, "the button must be a seated slot")
    if stacks[button] <= 0:
      raise newException(CosinoError, "the button must be a funded seat")
    result.order = newSeq[int](n)
    for position in 0 ..< n:
      result.order[position] = ring[(at + position) mod n]
  else:
    result.order = positionsFor(config, hand)
  result.posOf = newSeq[int](n)
  for position, slot in result.order:
    result.posOf[slot] = position
  result.button = result.order[0]
  var active = n
  if config.chipRace:
    active = 0
    for index in 0 ..< n:
      result.seats.add(Seat(
        name: names[index],
        stack: stacks[index],
        isOut: stacks[index] <= 0,
        handsWon: handsWon[index],
        net: stacks[index] - config.startingStack,
        mayRaise: stacks[index] > 0
      ))
      if stacks[index] > 0:
        inc active
    if active < 2:
      raise newException(CosinoError, "a hand needs two funded seats")
  else:
    for index in 0 ..< n:
      result.seats.add(Seat(
        name: names[index],
        stack: config.startingStack,
        handsWon: handsWon[index],
        net: net[index],
        mayRaise: true
      ))

  result.deck =
    if deck.len > 0: deck else: pairDeck(config, result.pair)

  var positionsNode = newJArray()
  for slot in result.order:
    positionsNode.add(%slot)
  result.addEvent(evHandStart, result.button,
    amount = (if config.variant == vHoldem: config.bigBlind else: config.ante),
    potAfter = 0, pair = result.pair, mirror = result.mirror,
    text = (
      if config.variant == vHoldem:
        $config.smallBlind & "/" & $config.bigBlind
      else:
        "ante " & $config.ante
    ),
    data = %*{"positions": positionsNode})

  case config.variant
  of vKuhn, vLeduc:
    ## One private card each, dealt to position 0 then position 1.
    for position in 0 ..< n:
      let slot = result.order[position]
      let hole = @[result.deck[result.dealIndex]]
      inc result.dealIndex
      result.seats[slot].holeCards = hole
      result.addEvent(evDeal, slot, cards = hole)
    for position in 0 ..< n:
      let slot = result.order[position]
      let posted = result.commit(slot, config.ante)
      result.addEvent(evAnte, slot, amount = posted,
        allIn = result.seats[slot].allIn,
        stackAfter = result.seats[slot].stack,
        betAfter = result.seats[slot].committed,
        potAfter = result.pot, text = "ante")
    ## Antes are dead money: nobody owes anything to open the round.
    for index in 0 ..< n:
      result.seats[index].committed = 0
    result.currentBet = 0
    result.minRaiseSize = result.wagerSize()
    result.progress(result.order[n - 1])
  of vHoldem:
    ## Heads-up, the button posts the small blind and acts first preflop;
    ## multiway, the blinds sit clockwise from the button. On the chip race
    ## "heads-up" means two FUNDED seats, and busted seats are skipped.
    if active == 2:
      result.sbSeat = result.button
      result.bbSeat = result.nextIn(result.button)
    elif config.chipRace:
      result.sbSeat = result.nextIn(result.button)
      result.bbSeat = result.nextIn(result.sbSeat)
    else:
      result.sbSeat = result.order[1]
      result.bbSeat = result.order[2]

    var seat = result.sbSeat
    for _ in 0 ..< active:
      let hole = @[result.deck[result.dealIndex],
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

    result.currentBet = config.bigBlind
    result.minRaiseSize = config.bigBlind
    result.progress(result.bbSeat)

# ---- Player actions ---------------------------------------------------------

proc recordSay*(sim: var Sim, seat: int, text: string) =
  if text.len == 0:
    return
  sim.addEvent(evSay, seat, text = truncateRunes(text, MaxSayLen))

proc applyAction*(sim: var Sim, seat: int, act: PlayerAction) =
  ## One player action. Raises CosinoError on anything illegal; the caller
  ## (game server) falls back to the scripted baseline on a rejection.
  if sim.done:
    raise newException(CosinoError, "the hand is over")
  if seat != sim.actingSeat:
    raise newException(CosinoError, "not this seat's turn")
  let limited = sim.config.variant.fixedLimit

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
    if sim.wagerCapReached():
      raise newException(CosinoError, "the wager cap for this round is reached")
    var target = act.amount
    let ceiling = sim.maxRaiseTo(seat)
    if limited:
      ## The wager size is fixed by the variant; `amount` is ignored.
      target = min(sim.wagerSize(), ceiling)
    if target <= 0 or target > ceiling:
      raise newException(CosinoError, "bet must be between 1 and the stack")
    if not limited and target < sim.minBet(seat) and target < ceiling:
      raise newException(CosinoError,
        "bet below the minimum (" & $sim.minBet(seat) & ")")
    discard sim.commit(seat, target - sim.seats[seat].committed)
    sim.currentBet = target
    sim.minRaiseSize = target
    sim.shortRaiseAccum = 0
    inc sim.wagers
    sim.reopen(seat)
    sim.addEvent(evAction, seat, action = akBet, amount = target,
      allIn = sim.seats[seat].allIn,
      stackAfter = sim.seats[seat].stack,
      betAfter = sim.seats[seat].committed, potAfter = sim.pot)
  of akRaise:
    if sim.currentBet == 0:
      raise newException(CosinoError, "nothing to raise — bet instead")
    if sim.wagerCapReached():
      raise newException(CosinoError, "the wager cap for this round is reached")
    if not sim.seats[seat].mayRaise:
      raise newException(CosinoError,
        "betting is closed to this seat this street")
    let ceiling = sim.maxRaiseTo(seat)
    var target = act.amount
    if limited:
      target = min(sim.currentBet + sim.wagerSize(), ceiling)
    if target <= sim.currentBet:
      raise newException(CosinoError, "a raise must exceed the current bet")
    if target > ceiling:
      raise newException(CosinoError, "cannot raise beyond the stack")
    let increment = target - sim.currentBet
    let full = limited or increment >= sim.minRaiseSize
    if not limited and target < ceiling and not full:
      raise newException(CosinoError,
        "raise below the minimum (to " & $sim.minRaiseTo(seat) & ")")
    discard sim.commit(seat, target - sim.seats[seat].committed)
    sim.currentBet = target
    inc sim.wagers
    if full:
      if not limited:
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
    sim.addEvent(evAction, seat, action = akRaise, amount = target,
      allIn = sim.seats[seat].allIn,
      stackAfter = sim.seats[seat].stack,
      betAfter = sim.seats[seat].committed, potAfter = sim.pot)

  sim.seats[seat].acted = true
  sim.seats[seat].mayRaise = false
  sim.progress(seat)

proc voidHand*(sim: var Sim) =
  ## The hard deadline abandoned a live hand: every chip committed to it goes
  ## back, so the sum of nets stays exactly zero and the hand is not scored.
  if sim.done:
    raise newException(CosinoError, "the hand is already over")
  var refunds = newJArray()
  for index in 0 ..< sim.seats.len:
    let back = sim.seats[index].totalCommitted
    sim.seats[index].stack += back
    sim.seats[index].totalCommitted = 0
    sim.seats[index].committed = 0
    sim.seats[index].allIn = false
    sim.pot -= back
    refunds.add(%back)
  sim.pot = 0
  sim.actingSeat = -1
  sim.addEvent(evHandVoid, -1, potAfter = 0, data = %*{"refunds": refunds})
  sim.done = true
  sim.voided = true

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
  if event.best.len > 0:
    var bestNode = newJArray()
    for card in event.best:
      bestNode.add(%card)
    result["best"] = bestNode
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
  if event.pair >= 0:
    result["pair"] = %event.pair
  if event.mirror:
    result["mirror"] = %true
  if event.text.len > 0:
    result["text"] = %event.text
  if not event.data.isNil:
    result["data"] = event.data

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
    pair: node{"pair"}.getInt(-1),
    mirror: node{"mirror"}.getBool(false),
    text: node{"text"}.getStr("")
  )
  if node.hasKey("cards"):
    for card in node["cards"]:
      result.cards.add(card.getInt())
  if node.hasKey("best"):
    for card in node["best"]:
      result.best.add(card.getInt())
  if node.hasKey("action"):
    result.action = parseEnum[ActionKind](node["action"].getStr())
  if node.hasKey("data"):
    result.data = node["data"]

# ---- Calibration and audit, both pure functions of the event log ------------

proc calibFromEvents*(config: GameConfig, events: seq[GameEvent]):
    seq[CalibResult] =
  ## Exact exploitability per SLOT for the calibration rungs; an empty seq for
  ## Hold'em, where no exact best response exists.
  if not config.variant.fixedLimit:
    return @[]
  let calibVariant = if config.variant == vKuhn: cvKuhn else: cvLeduc
  let n = config.players.len
  var observed = newSeq[Table[string, seq[int]]](n)
  for index in 0 ..< n:
    observed[index] = initTable[string, seq[int]]()
  var decisions = newSeq[int](n)

  var positions = newSeq[int](n)     ## slot -> position
  var cardOf = newSeq[int](n)
  var boardRank = -1
  var history = ""

  for event in events:
    case event.kind
    of evHandStart:
      history = ""
      boardRank = -1
      for index in 0 ..< n:
        cardOf[index] = -1
      if not event.data.isNil and event.data.hasKey("positions"):
        for position, slot in event.data["positions"].getElems():
          positions[slot.getInt()] = position
    of evDeal:
      if event.cards.len > 0:
        cardOf[event.seat] = event.cards[0].rank
    of evBoard:
      if event.cards.len > 0:
        boardRank = event.cards[0].rank
      history.add("/")
    of evAction:
      let slot = event.seat
      let position = positions[slot]
      let key = infosetKey(position, cardOf[slot], boardRank, history)
      let legal = legalActions(calibVariant, history)
      let letter =
        case event.action
        of akFold: aFold
        of akCheck, akCall: aCheckCall
        of akBet, akRaise: aBetRaise
      var slotOf = -1
      for index, act in legal:
        if act == letter:
          slotOf = index
      if slotOf >= 0:
        if not observed[slot].hasKey(key):
          observed[slot][key] = newSeq[int](legal.len)
        observed[slot][key][slotOf].inc
        inc decisions[slot]
      history.add(actionLetter(letter))
    else:
      discard

  for slot in 0 ..< n:
    result.add(exploitabilityOf(calibVariant, observed[slot],
      decisions[slot]))

proc auditFromEvents*(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## Collusion audit — a pure function of the event log plus the seed, so the
  ## server and the wasm viewer compute identical output. Reporting only: it
  ## never alters a score.
  auditEvents(config, events)

# ---- Match ------------------------------------------------------------------

proc initMatch*(config: GameConfig): Match =
  var settled = config
  settled.validate()
  if settled.seatOrder.len != settled.players.len:
    settled.seatOrder = settled.seatOrderFor()
  let names = tableNames(settled.players, settled.seed)
  let n = settled.players.len
  result = Match(
    config: settled,
    names: names,
    net: newSeq[int](n),
    handsWon: newSeq[int](n),
    stackOffs: newSeq[int](n),
    reason: erComplete
  )
  if settled.chipRace:
    var stacks = newSeq[int](n)
    for index in 0 ..< n:
      stacks[index] = settled.startingStack
    ## The opening button is drawn from the seed, like the deck and aliases.
    let button = settled.seatOrder[((settled.seed mod n) + n) mod n]
    result.sim = initHand(settled, 0, names, result.handsWon, result.net,
      stacks = stacks, button = button)
  else:
    result.sim = initHand(settled, 0, names, result.handsWon, result.net)

proc allEvents*(match: Match): seq[GameEvent] =
  match.history & match.sim.events

proc fundedSeats*(match: Match): int =
  for seat in match.sim.seats:
    if seat.stack > 0:
      inc result

proc finishHand*(match: var Match) =
  ## Accounts the finished hand. Deliberately does NOT deal the next one — the
  ## caller can stop between hands without a dealt-but-unplayed hand
  ## corrupting the result.
  if not match.sim.done or match.done:
    raise newException(CosinoError, "no finished hand to fold in")
  inc match.handsPlayed
  if not match.sim.voided:
    inc match.handsScored
    for index in 0 ..< match.config.players.len:
      if match.config.chipRace:
        match.net[index] =
          match.sim.seats[index].stack - match.config.startingStack
      else:
        match.net[index] +=
          match.sim.seats[index].stack - match.config.startingStack
        if match.config.variant == vHoldem and
            match.sim.seats[index].stack == 0:
          inc match.stackOffs[index]
      match.handsWon[index] = match.sim.seats[index].handsWon
  if match.handsPlayed >= match.config.hands or
      (match.config.chipRace and match.fundedSeats() < 2):
    match.done = true
    match.reason = erComplete

proc nextHand*(match: var Match) =
  ## Deals the next hand of a live match.
  if match.done or not match.sim.done:
    raise newException(CosinoError, "the match is over or a hand is live")
  if match.config.chipRace:
    var stacks: seq[int]
    for seat in match.sim.seats:
      stacks.add(seat.stack)
    ## The button walks clockwise around the ring to the next funded seat.
    let n = stacks.len
    var position = match.sim.posOf[match.sim.button]
    var button = -1
    for offset in 1 .. n:
      let slot = match.sim.order[(position + offset) mod n]
      if stacks[slot] > 0:
        button = slot
        break
    let hand = match.sim.hand + 1
    match.history.add(match.sim.events)
    match.sim = initHand(match.config, hand, match.names,
      match.handsWon, match.net, stacks = stacks, button = button)
  else:
    match.history.add(match.sim.events)
    match.sim = initHand(match.config, match.sim.hand + 1, match.names,
      match.handsWon, match.net)

proc endMatchEarly*(match: var Match, reason: EndReason) =
  ## Stop after the hand just scored. The hosted platform kills an episode
  ## that outlives its timeout and keeps NOTHING, so a short honest match
  ## always beats a long one that never lands.
  match.done = true
  match.reason = reason

proc voidLiveHand*(match: var Match) =
  ## The hard deadline caught a hand in progress.
  match.sim.voidHand()
  match.finishHand()

proc pairsComplete*(match: Match): int =
  match.handsScored div 2

proc unpairedHands*(match: Match): int =
  match.handsScored mod 2

proc finishMatch*(match: var Match) =
  ## Writes the load-bearing tail: one `calib` event per seat on the
  ## calibration rungs, one `audit` event per flagged pair at six-max, and
  ## `matchEnd` last, carrying the reason, the scored-hand count, the seed and
  ## the whole audit object. Everything downstream re-derives from these.
  if match.ended:
    return
  match.ended = true
  match.done = true
  let events = match.allEvents()
  var tail: seq[GameEvent]

  let calib = calibFromEvents(match.config, events)
  for slot, entry in calib:
    tail.add(GameEvent(
      kind: evCalib, hand: max(match.sim.hand, 0), seat: slot,
      street: stShowdown, stackAfter: -1, betAfter: -1, potAfter: -1,
      pair: -1,
      data: %*{
        "exploitability": entry.exploitability,
        "coverage": entry.coverage,
        "fill": entry.fill,
        "decisions": entry.decisions
      }
    ))

  let auditNode = auditFromEvents(match.config, events)
  for flag in auditNode["flagged"]:
    tail.add(GameEvent(
      kind: evAudit, hand: max(match.sim.hand, 0), seat: -1,
      street: stShowdown, stackAfter: -1, betAfter: -1, potAfter: -1,
      pair: -1, data: flag
    ))

  tail.add(GameEvent(
    kind: evMatchEnd, hand: max(match.sim.hand, 0), seat: -1,
    street: stShowdown, stackAfter: -1, betAfter: -1, potAfter: -1,
    pair: -1,
    data: %*{
      "reason": $match.reason,
      "handsScored": match.handsScored,
      "seed": match.config.seed,
      "audit": auditNode
    }
  ))
  match.sim.events.add(tail)

proc resultsFromEvents*(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## The whole platform-facing result, re-derived from the recorded log. The
  ## wall-clock stop is a recorded event, so a `deadline` episode re-derives
  ## exactly like a `complete` one.
  let n = config.players.len
  var net = newSeq[int](n)
  var handsWon = newSeq[int](n)
  var stackOffs = newSeq[int](n)
  var busted = newSeq[bool](n)
  var handsPlayed = 0
  var handsScored = 0
  var reason = erComplete
  var seed = config.seed
  var auditNode = %*{"pairs": newJArray(), "flagged": newJArray(),
    "power": %*{"hands": 0, "contestedMin": 0, "contestedMedian": 0,
      "equitySamples": EquitySamples}}
  var exploitability = newJArray()
  var coverage = newJArray()
  var fill = ""
  var wonThisHand = newSeq[bool](n)
  var explByseat = newSeq[JsonNode](n)
  var covBySeat = newSeq[JsonNode](n)
  for index in 0 ..< n:
    explByseat[index] = newJNull()
    covBySeat[index] = newJNull()

  for event in events:
    case event.kind
    of evHandStart:
      inc handsPlayed
      for index in 0 ..< n:
        wonThisHand[index] = false
    of evAward:
      if event.text != "returned" and event.seat >= 0 and
          not wonThisHand[event.seat]:
        wonThisHand[event.seat] = true
        inc handsWon[event.seat]
    of evStackOff:
      if event.seat >= 0:
        inc stackOffs[event.seat]
    of evBust:
      if event.seat >= 0:
        busted[event.seat] = true
    of evHandEnd:
      if not event.data.isNil and event.data.hasKey("net"):
        for index, value in event.data["net"].getElems():
          if index < n:
            net[index] = value.getInt()
    of evCalib:
      if event.seat >= 0 and event.seat < n and not event.data.isNil:
        explByseat[event.seat] = event.data{"exploitability"}
        covBySeat[event.seat] = event.data{"coverage"}
        fill = event.data{"fill"}.getStr("")
    of evMatchEnd:
      if not event.data.isNil:
        reason = parseEnum[EndReason](event.data{"reason"}.getStr("complete"))
        handsScored = event.data{"handsScored"}.getInt(0)
        seed = event.data{"seed"}.getInt(config.seed)
        if event.data.hasKey("audit"):
          auditNode = event.data["audit"]
    else:
      discard

  for index in 0 ..< n:
    exploitability.add(
      if explByseat[index].isNil: newJNull() else: explByseat[index])
    coverage.add(if covBySeat[index].isNil: newJNull() else: covBySeat[index])

  let scale = max(handsScored, 1)
  let unit = if config.variant == vHoldem: config.bigBlind else: config.ante
  var best = low(int)
  for value in net:
    best = max(best, value)

  var names = newJArray()
  var scores = newJArray()
  var winNode = newJArray()
  var netNode = newJArray()
  var netPerHand = newJArray()
  var unitsPerHand = newJArray()
  var handsWonNode = newJArray()
  var stackOffsNode = newJArray()
  var stacksNode = newJArray()
  var bustedNode = newJArray()
  var seatOrderNode = newJArray()
  for index in 0 ..< n:
    names.add(%config.players[index].name)
    ## 1/n + net / (n * S * H): exactly [0, 1], summing to 1, and at H = 1 it
    ## degenerates to a plain chip share. The chip race IS that degenerate
    ## case: stacks carry, so the final net is one number and the score is
    ## the final chip share.
    let handsNorm = if config.chipRace: 1 else: handsScored
    let share =
      if handsScored == 0: 1.0 / n.float
      else: 1.0 / n.float +
        net[index].float /
          (n.float * config.startingStack.float * handsNorm.float)
    scores.add(%share)
    winNode.add(%(net[index] == best))
    netNode.add(%net[index])
    netPerHand.add(%(net[index].float / scale.float))
    unitsPerHand.add(%(net[index].float / (max(unit, 1).float * scale.float)))
    handsWonNode.add(%handsWon[index])
    stackOffsNode.add(%stackOffs[index])
    if config.chipRace:
      stacksNode.add(%(net[index] + config.startingStack))
      bustedNode.add(%busted[index])
  for slot in config.seatOrder:
    seatOrderNode.add(%slot)

  result = %*{
    "names": names,
    "scores": scores,
    "win": winNode,
    "net": netNode,
    "netPerHand": netPerHand,
    "unitsPerHand": unitsPerHand,
    "handsWon": handsWonNode,
    "stackOffs": stackOffsNode,
    "exploitability": exploitability,
    "exploitabilityCoverage": coverage,
    "exploitabilityFill": fill,
    "audit": auditNode,
    "variant": $config.variant,
    "chipRace": config.chipRace,
    "seats": n,
    "handsPlayed": handsPlayed,
    "handsScored": handsScored,
    "hands": config.hands,
    "pairsComplete": (if config.duplicate: handsScored div 2 else: 0),
    "unpairedHands": (if config.duplicate: handsScored mod 2 else: 0),
    "startingStack": config.startingStack,
    "ante": config.ante,
    "smallBlind": config.smallBlind,
    "bigBlind": config.bigBlind,
    "seed": seed,
    "seatOrder": seatOrderNode,
    "reason": $reason
  }
  if config.chipRace:
    ## The chip race's own read of the same numbers: the carried stack and
    ## who busted out of it.
    result["stacks"] = stacksNode
    result["busted"] = bustedNode

proc resultsJson*(match: Match, fallbacks: seq[int] = @[],
    forcedFolds: seq[int] = @[], decisions: seq[int] = @[]): JsonNode =
  let n = match.config.players.len
  result = resultsFromEvents(match.config, match.allEvents())
  var fallbackNode = newJArray()
  var forcedNode = newJArray()
  var decisionNode = newJArray()
  for index in 0 ..< n:
    fallbackNode.add(%(if index < fallbacks.len: fallbacks[index] else: 0))
    forcedNode.add(%(if index < forcedFolds.len: forcedFolds[index] else: 0))
    decisionNode.add(%(if index < decisions.len: decisions[index] else: 0))
  result["fallbacks"] = fallbackNode
  result["forcedFolds"] = forcedNode
  result["decisions"] = decisionNode

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
      "net": seat.net,
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
    "pair": sim.pair,
    "mirror": sim.mirror,
    "button": sim.button,
    "currentBet": sim.currentBet,
    "handDone": sim.done
  }

# ---- Replay -----------------------------------------------------------------

type
  ReplayFrame* = object
    ## One scrub position: the reconstructed table after an event prefix
    ## (frames[i] = state after events[0..<i]).
    seats*: seq[Seat]
    board*: seq[int]
    pot*: int
    street*: Street
    hand*: int
    pair*: int
    mirror*: bool
    button*: int
    currentBet*: int
    acting*: int      ## seat about to act (the next event's actor), or -1
    handDone*: bool

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[ReplayFrame] =
  ## Re-derives the state timeline from a recorded event log. Events carry
  ## amounts and stacks-after, so this never re-runs the betting engine.
  let n = config.players.len
  var frame = ReplayFrame(
    street: stPreflop,
    acting: -1,
    button: -1,
    pair: -1
  )
  var wonThisHand = newSeq[bool](n)
  ## `net` on a frame is the cumulative net BEFORE the current hand's chips
  ## move, so a viewer's running total is always net + (stack - startingStack).
  ## The handEnd figure therefore lands at the NEXT handStart.
  var pendingNet = newSeq[int](n)
  for index in 0 ..< n:
    frame.seats.add(Seat(
      name:
        if index < config.players.len: config.players[index].name
        else: "Seat " & $(index + 1),
      stack: config.startingStack
    ))
  result.add(frame)
  for at, event in events:
    case event.kind
    of evHandStart:
      frame.hand = event.hand
      frame.button = event.seat
      frame.pair = event.pair
      frame.mirror = event.mirror
      frame.board = @[]
      frame.pot = 0
      frame.street = stPreflop
      frame.currentBet = 0
      frame.handDone = false
      for index in 0 ..< n:
        ## The chip race carries the stack (and any bust) into the next hand;
        ## the ladder resets every seat to the buy-in.
        if not config.chipRace:
          frame.seats[index].stack = config.startingStack
        frame.seats[index].committed = 0
        frame.seats[index].totalCommitted = 0
        frame.seats[index].folded = false
        frame.seats[index].allIn = false
        frame.seats[index].holeCards = @[]
        frame.seats[index].revealed = false
        frame.seats[index].net = pendingNet[index]
        wonThisHand[index] = false
    of evDeal:
      frame.seats[event.seat].holeCards = event.cards
    of evAnte, evBlind, evAction:
      if event.kind == evAction and event.action == akFold:
        frame.seats[event.seat].folded = true
      frame.seats[event.seat].totalCommitted +=
        max(event.betAfter - frame.seats[event.seat].committed, 0)
      frame.seats[event.seat].stack = event.stackAfter
      frame.seats[event.seat].committed = event.betAfter
      frame.seats[event.seat].allIn = event.allIn
      frame.currentBet = max(frame.currentBet, event.betAfter)
      frame.pot = event.potAfter
      frame.street = event.street
      if event.kind == evAnte:
        ## Antes are dead money: nothing is owed to open the round.
        var settled = true
        for index in 0 ..< n:
          if frame.seats[index].committed != frame.seats[0].committed:
            settled = false
        if settled:
          for index in 0 ..< n:
            frame.seats[index].committed = 0
          frame.currentBet = 0
    of evSay:
      discard
    of evBoard:
      frame.board.add(event.cards)
      frame.street = event.street
      frame.currentBet = 0
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
        if not wonThisHand[event.seat]:
          wonThisHand[event.seat] = true
          inc frame.seats[event.seat].handsWon
    of evStackOff:
      discard
    of evBust:
      frame.seats[event.seat].isOut = true
    of evHandEnd:
      frame.pot = 0
      frame.handDone = true
      if not event.data.isNil and event.data.hasKey("net"):
        for index, value in event.data["net"].getElems():
          if index < n:
            pendingNet[index] = value.getInt()
    of evHandVoid:
      frame.pot = 0
      frame.handDone = true
      if not event.data.isNil and event.data.hasKey("refunds"):
        for index, value in event.data["refunds"].getElems():
          if index < n:
            frame.seats[index].stack += value.getInt()
            frame.seats[index].committed = 0
    of evCalib, evAudit, evMatchEnd:
      discard
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
      "net": seat.net,
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
    "pair": frame.pair,
    "mirror": frame.mirror,
    "button": frame.button,
    "currentBet": frame.currentBet,
    "handDone": frame.handDone
  }

proc statesFromEvents*(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.frameStateJson())

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  let node = payload["config"]
  result.variantDefaults(
    parseEnum[Variant](node{"variant"}.getStr("holdem")))
  result.startingStack = node{"startingStack"}.getInt(result.startingStack)
  result.ante = node{"ante"}.getInt(result.ante)
  result.smallBlind = node{"smallBlind"}.getInt(result.smallBlind)
  result.bigBlind = node{"bigBlind"}.getInt(result.bigBlind)
  result.hands = node{"hands"}.getInt(result.hands)
  result.duplicate = node{"duplicate"}.getBool(true)
  result.chipRace = node{"chipRace"}.getBool(false)
  if result.chipRace:
    result.duplicate = false
  result.seed = node{"seed"}.getInt(0)
  result.seatOrder = @[]
  if node.hasKey("seatOrder"):
    for slot in node["seatOrder"]:
      result.seatOrder.add(slot.getInt())
  ## The replay carries the episode's fitted table; never re-fit it.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc replayConfigJson*(config: GameConfig): JsonNode =
  var bets = newJArray()
  for size in config.variant.betSizes(config.bigBlind):
    bets.add(%size)
  var seatOrderNode = newJArray()
  for slot in config.seatOrder:
    seatOrderNode.add(%slot)
  %*{
    "variant": $config.variant,
    "seats": config.players.len,
    "startingStack": config.startingStack,
    "ante": config.ante,
    "smallBlind": config.smallBlind,
    "bigBlind": config.bigBlind,
    "bets": bets,
    "maxWagers": (
      if config.variant.fixedLimit: config.variant.maxWagers() else: 0),
    "hands": config.hands,
    "duplicate": config.duplicate,
    "chipRace": config.chipRace,
    "seatOrder": seatOrderNode,
    "seed": config.seed,
    "sampled": true,
    "gameVersion": GameVersion
  }
