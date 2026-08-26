## Collusion audit for the six-max rung.
##
## A PURE function of the event log plus the seed: the server and the wasm
## replay viewer compute identical output from the same bytes. It is
## REPORTING ONLY — it never alters a score, never disqualifies a seat.
##
## For every pot slice and every fold it measures how much of its equity a
## seat surrendered and to whom, compares that against how much it leaks to
## the field, and flags pairs that leak to each other far more than to
## everyone else.
##
## Showdown slices are priced on the FINAL board, so a completed hand books no
## surrender at all and pure card luck cannot masquerade as a leak. Showdown
## attribution is SIGNED (winning more than your equity books a negative
## surrender), so `surrender`, `rate` and `bias` may all be negative; only
## positive bias can raise a flag.
##
## NAMED LIMITATION: the surrender signal therefore comes entirely from the
## FOLD term. The audit flags folding-good-hands collusion -- dumping and soft
## play -- but does NOT flag "calling off with the worst of it to feed a
## partner". That vector stays visible in the reported `netFlow[a][b]`.

import std/[algorithm, json, math, random, strutils], cards, types

const
  ## Monte-Carlo runouts per equity measurement. Deterministic: the RNG is
  ## seeded from the replay's own seed, hand index and slice index, so the
  ## browser re-derives the same numbers as the server.
  EquitySamples* = 2000
  ## A pair needs this many contested hands before any flag is considered.
  ContestedMin* = 4
  ## Mutual leak, in big blinds per contested hand.
  SoftPlayBias* = 0.75
  ## One-way leak. Chip dumping is directional, so it gets a higher bar.
  DumpBias* = 2.0

type
  FoldRecord = object
    slot: int
    board: seq[int]
    pot: int
    callCost: int
    contrib: seq[int]
    live: seq[int]
    ordinal: int

  HandRecord = object
    hand: int
    hole: seq[seq[int]]
    board: seq[int]
    committed: seq[int]
    folded: seq[bool]
    folds: seq[FoldRecord]
    awards: seq[seq[int]]     ## slice index -> per-slot payout
    sweep: seq[int]           ## per-slot "sweep" payout
    complete: bool

# ---- A fast seven-card evaluator, for the Monte Carlo -----------------------

proc packRank7(category: int, ranks: openArray[int]): int =
  result = category shl 20
  for index in 0 ..< 5:
    let value = if index < ranks.len: ranks[index] else: 0
    result = result or (value shl (16 - 4 * index))

proc straightHigh7(rankSet: set[0 .. 12]): int =
  for high in countdown(12, 4):
    var ok = true
    for step in 0 .. 4:
      if (high - step) notin rankSet:
        ok = false
        break
    if ok:
      return high
  if 12 in rankSet and 0 in rankSet and 1 in rankSet and 2 in rankSet and
      3 in rankSet:
    return 3
  -1

proc eval7*(cards: openArray[int]): int =
  ## Same packed rank as `eval5`/`evalBest`, in one pass instead of twenty-one
  ## five-card evaluations. The Monte Carlo runs millions of these.
  var counts: array[13, int]
  var suitCounts: array[4, int]
  var suitSets: array[4, set[0 .. 12]]
  var rankSet: set[0 .. 12]
  for card in cards:
    let r = card.rank
    let s = card.suit
    inc counts[r]
    inc suitCounts[s]
    suitSets[s].incl(r)
    rankSet.incl(r)

  for suit in 0 .. 3:
    if suitCounts[suit] >= 5:
      let straight = straightHigh7(suitSets[suit])
      if straight >= 0:
        return packRank7(HandStraightFlush, [straight])
      var top: seq[int]
      for value in countdown(12, 0):
        if value in suitSets[suit]:
          top.add(value)
          if top.len == 5:
            break
      return packRank7(HandFlush, top)

  var quads, trips, pairs, singles: seq[int]
  for value in countdown(12, 0):
    case counts[value]
    of 4: quads.add(value)
    of 3: trips.add(value)
    of 2: pairs.add(value)
    of 1: singles.add(value)
    else: discard

  if quads.len >= 1:
    var kicker = -1
    for value in countdown(12, 0):
      if value != quads[0] and counts[value] > 0:
        kicker = value
        break
    return packRank7(HandQuads, [quads[0], kicker])
  if trips.len >= 2:
    return packRank7(HandFullHouse, [trips[0], trips[1]])
  if trips.len == 1 and pairs.len >= 1:
    return packRank7(HandFullHouse, [trips[0], pairs[0]])

  let straight = straightHigh7(rankSet)
  if straight >= 0:
    return packRank7(HandStraight, [straight])
  if trips.len == 1:
    var kickers: seq[int]
    for value in countdown(12, 0):
      if value != trips[0] and counts[value] > 0:
        kickers.add(value)
        if kickers.len == 2:
          break
    return packRank7(HandTrips, [trips[0], kickers[0], kickers[1]])
  if pairs.len >= 2:
    var kicker = -1
    for value in countdown(12, 0):
      if value != pairs[0] and value != pairs[1] and counts[value] > 0:
        kicker = value
        break
    return packRank7(HandTwoPair, [pairs[0], pairs[1], kicker])
  if pairs.len == 1:
    var kickers: seq[int]
    for value in countdown(12, 0):
      if value != pairs[0] and counts[value] > 0:
        kickers.add(value)
        if kickers.len == 3:
          break
    return packRank7(HandPair,
      [pairs[0], kickers[0], kickers[1], kickers[2]])
  var top: seq[int]
  for value in countdown(12, 0):
    if counts[value] > 0:
      top.add(value)
      if top.len == 5:
        break
  packRank7(HandHighCard, top)

# ---- Equity -----------------------------------------------------------------

proc equities*(hole: seq[seq[int]], slots: seq[int], board: seq[int],
    dead: seq[int], rng: var Rand, samples: int): seq[float] =
  ## Exact win-share probability per slot in `slots`, splits counted
  ## fractionally. With a complete board this is a single exact evaluation;
  ## with cards to come it is Monte Carlo over `samples` runouts.
  result = newSeq[float](slots.len)
  if slots.len == 0:
    return
  if slots.len == 1:
    result[0] = 1.0
    return
  var used: set[0 .. 51]
  for card in board:
    used.incl(card)
  for card in dead:
    used.incl(card)
  var deck: seq[int]
  for card in 0 ..< 52:
    if card notin used:
      deck.add(card)
  let toCome = 5 - board.len
  let runs = if toCome <= 0: 1 else: samples
  var runout = newSeq[int](5)
  for run in 0 ..< runs:
    for index, card in board:
      runout[index] = card
    if toCome > 0:
      ## Partial Fisher-Yates over a scratch copy: sampling without
      ## replacement, deterministic in `rng`.
      var pool = deck
      for index in 0 ..< toCome:
        let pick = index + rng.rand(pool.len - 1 - index)
        swap(pool[index], pool[pick])
        runout[board.len + index] = pool[index]
    var best = -1
    var winners = 0
    var ranks = newSeq[int](slots.len)
    for index, slot in slots:
      let seven = @[hole[slot][0], hole[slot][1]] & runout
      ranks[index] = eval7(seven)
      if ranks[index] > best:
        best = ranks[index]
    for value in ranks:
      if value == best:
        inc winners
    for index, value in ranks:
      if value == best:
        result[index] += 1.0 / winners.float
  for index in 0 ..< result.len:
    result[index] = result[index] / runs.float

# ---- Event parsing ----------------------------------------------------------

proc sliceIndexOf(label: string): int =
  if label == "main": 0
  elif label.len > 5 and label[0 .. 4] == "side ":
    try: parseInt(label[5 .. ^1]) except ValueError: -1
  else: -1

proc parseHands(config: GameConfig, events: seq[GameEvent]): seq[HandRecord] =
  let n = config.players.len
  var record: HandRecord
  var open = false
  var streetBet = newSeq[int](n)
  var currentBet = 0
  var foldOrdinal = 0

  proc reset(hand: int) =
    record = HandRecord(hand: hand)
    record.hole = newSeq[seq[int]](n)
    record.committed = newSeq[int](n)
    record.folded = newSeq[bool](n)
    record.awards = @[]
    record.sweep = newSeq[int](n)
    for index in 0 ..< n:
      streetBet[index] = 0
    currentBet = 0
    foldOrdinal = 0

  for event in events:
    case event.kind
    of evHandStart:
      reset(event.hand)
      open = true
    of evDeal:
      if open and event.seat >= 0:
        record.hole[event.seat] = event.cards
    of evAnte, evBlind:
      if open and event.seat >= 0 and event.betAfter >= 0:
        record.committed[event.seat] += event.betAfter - streetBet[event.seat]
        streetBet[event.seat] = event.betAfter
        currentBet = max(currentBet, event.betAfter)
    of evAction:
      if not open:
        continue
      let slot = event.seat
      if event.action == akFold:
        var live: seq[int]
        for index in 0 ..< n:
          if index != slot and not record.folded[index]:
            live.add(index)
        record.folds.add(FoldRecord(
          slot: slot,
          board: record.board,
          pot: max(event.potAfter, 0),
          callCost: max(currentBet - streetBet[slot], 0),
          contrib: record.committed,
          live: live,
          ordinal: foldOrdinal
        ))
        inc foldOrdinal
        record.folded[slot] = true
      if event.betAfter >= 0:
        record.committed[slot] += event.betAfter - streetBet[slot]
        streetBet[slot] = event.betAfter
        currentBet = max(currentBet, event.betAfter)
    of evBoard:
      if open:
        record.board.add(event.cards)
        for index in 0 ..< n:
          streetBet[index] = 0
        currentBet = 0
    of evAward:
      if not open or event.seat < 0:
        continue
      if event.text == "returned":
        record.committed[event.seat] -= event.amount
      elif event.text == "sweep":
        record.sweep[event.seat] += event.amount
      else:
        let index = sliceIndexOf(event.text)
        if index >= 0:
          while record.awards.len <= index:
            record.awards.add(newSeq[int](n))
          record.awards[index][event.seat] += event.amount
    of evHandEnd:
      if open:
        record.complete = true
        result.add(record)
        open = false
    of evHandVoid:
      ## Refunded and unscored: it never happened.
      open = false
    else:
      discard

# ---- The audit --------------------------------------------------------------

proc emptyAudit(): JsonNode =
  %*{
    "pairs": newJArray(),
    "flagged": newJArray(),
    "power": {
      "hands": 0,
      "contestedMin": 0,
      "contestedMedian": 0,
      "equitySamples": EquitySamples
    }
  }

proc auditEvents*(config: GameConfig, events: seq[GameEvent],
    samples = EquitySamples): JsonNode =
  ## `{pairs, flagged, power}`. Runs only where collusion is possible at all
  ## (Hold'em with three or more seats); two-seat variants report empty.
  let n = config.players.len
  if config.variant != vHoldem or n < 3:
    return emptyAudit()

  var surrender = newSeq[seq[float]](n)
  var contested = newSeq[seq[int]](n)
  var flow = newSeq[seq[float]](n)
  for index in 0 ..< n:
    surrender[index] = newSeq[float](n)
    contested[index] = newSeq[int](n)
    flow[index] = newSeq[float](n)

  let hands = parseHands(config, events)
  for record in hands:
    if not record.complete:
      continue
    ## Every hole card the deal put out is physically gone from the deck.
    var dead: seq[int]
    for cards in record.hole:
      for card in cards:
        dead.add(card)

    for a in 0 ..< n:
      for b in a + 1 ..< n:
        if record.committed[a] > 0 and record.committed[b] > 0:
          inc contested[a][b]
          inc contested[b][a]

    ## --- Folds: equity given away by folding a hand worth more than its
    ## price. Folding correctly scores about zero.
    for fold in record.folds:
      if fold.live.len == 0 or fold.pot <= 0:
        continue
      if record.hole[fold.slot].len < 2:
        continue
      var group = @[fold.slot] & fold.live
      var usable = true
      for slot in group:
        if record.hole[slot].len < 2:
          usable = false
      if not usable:
        continue
      var rng = initRand(int64(config.seed) * 1_000_003 +
        int64(record.hand) * 97 + int64(100 + fold.ordinal))
      let shares = equities(record.hole, group, fold.board, dead, rng, samples)
      let loss = max(0.0, shares[0] * fold.pot.float - fold.callCost.float)
      if loss <= 0.0:
        continue
      var denom = 0.0
      for other in 0 ..< n:
        if other != fold.slot:
          denom += fold.contrib[other].float
      if denom <= 0.0:
        continue
      for other in 0 ..< n:
        if other != fold.slot and fold.contrib[other] > 0:
          surrender[fold.slot][other] +=
            loss * fold.contrib[other].float / denom

    ## --- Showdown slices.
    var live: seq[int]
    for index in 0 ..< n:
      if not record.folded[index]:
        live.add(index)
    if live.len < 2:
      ## Uncontested: the whole pot is one slice, won by the last seat
      ## standing. There is no equity to surrender at showdown (the folds
      ## above already accounted for it), but the chips did flow.
      var totalContrib = 0
      for value in record.committed:
        totalContrib += max(value, 0)
      if live.len == 1 and totalContrib > 0:
        let winner = live[0]
        for c in 0 ..< n:
          if c != winner and record.committed[c] > 0:
            flow[c][winner] += totalContrib.float *
              record.committed[c].float / totalContrib.float
      continue
    var levels: seq[int]
    for slot in live:
      if record.committed[slot] > 0 and record.committed[slot] notin levels:
        levels.add(record.committed[slot])
    levels.sort()

    var previous = 0
    for sliceIndex, level in levels:
      var contrib = newSeq[int](n)
      var slice = 0
      for index in 0 ..< n:
        contrib[index] = max(0, min(record.committed[index], level) - previous)
        slice += contrib[index]
      previous = level
      if slice <= 0:
        continue
      var eligible: seq[int]
      for slot in live:
        if record.committed[slot] >= level:
          eligible.add(slot)
      var usable = true
      for slot in eligible:
        if record.hole[slot].len < 2:
          usable = false
      if not usable:
        continue
      ## Showdown equity is measured on the FINAL board (addendum 2): an exact
      ## evaluation, so eq is 0 or 1 up to splits and loss_a is 0 for every
      ## hand played to completion. Pricing the slice at the last betting
      ## action instead booked the realised runout of a single pre-river
      ## all-in as half a stack of "surrender" against a 2 bb bar, which
      ## flagged honest play. The seeded Monte Carlo now serves the fold case
      ## only. `equities` still takes an rng because a complete board makes it
      ## a single exact evaluation and never draws from it.
      var rng = initRand(int64(config.seed) * 1_000_003 +
        int64(record.hand) * 97 + int64(sliceIndex))
      let shares = equities(record.hole, eligible, record.board, dead, rng,
        samples)
      var equity = newSeq[float](n)
      for index, slot in eligible:
        equity[slot] = shares[index]

      var actual = newSeq[int](n)
      if sliceIndex < record.awards.len:
        for index in 0 ..< n:
          actual[index] = record.awards[sliceIndex][index]
      if sliceIndex == levels.high:
        for index in 0 ..< n:
          actual[index] += record.sweep[index]

      var totalContrib = 0
      for value in contrib:
        totalContrib += value

      for a in 0 ..< n:
        if contrib[a] <= 0:
          continue
        ## SIGNED, deliberately unclamped (addendum 1): a seat that wins more
        ## than its equity books a NEGATIVE surrender, so symmetric variance
        ## cancels across hands instead of accumulating one-sidedly. Only
        ## positive bias can raise a flag. (The fold case below keeps its own
        ## internal max(0, ...): folding correctly must still score ~0.)
        let loss = equity[a] * slice.float - actual[a].float
        var denom = 0.0
        for b in 0 ..< n:
          if b != a:
            denom += contrib[b].float
        if denom <= 0.0:
          continue
        for b in 0 ..< n:
          if b != a and contrib[b] > 0:
            surrender[a][b] += loss * contrib[b].float / denom

      if totalContrib > 0:
        for b in 0 ..< n:
          if actual[b] <= 0:
            continue
          for c in 0 ..< n:
            if c != b and contrib[c] > 0:
              flow[c][b] +=
                actual[b].float * contrib[c].float / totalContrib.float

  ## --- Rates, bias, flags.
  var field = newSeq[float](n)
  for a in 0 ..< n:
    var lost = 0.0
    var played = 0
    for c in 0 ..< n:
      if c != a:
        lost += surrender[a][c]
        played += contested[a][c]
    field[a] = lost / max(played, 1).float

  var bias = newSeq[seq[float]](n)
  for a in 0 ..< n:
    bias[a] = newSeq[float](n)
    for b in 0 ..< n:
      if b == a:
        continue
      bias[a][b] = surrender[a][b] / max(contested[a][b], 1).float - field[a]

  let bb = max(config.bigBlind, 1).float
  var pairsNode = newJArray()
  var flaggedNode = newJArray()
  var contestedValues: seq[int]
  for a in 0 ..< n:
    for b in a + 1 ..< n:
      let netFlow = flow[a][b] - flow[b][a]
      contestedValues.add(contested[a][b])
      pairsNode.add(%*{
        "a": a,
        "b": b,
        "contested": contested[a][b],
        "surrenderAB": surrender[a][b],
        "surrenderBA": surrender[b][a],
        "biasAB": bias[a][b],
        "biasBA": bias[b][a],
        "netFlow": netFlow
      })
      if contested[a][b] < ContestedMin:
        continue
      if min(bias[a][b], bias[b][a]) > SoftPlayBias * bb:
        flaggedNode.add(%*{
          "a": a, "b": b, "flag": "soft-play",
          "biasAB": bias[a][b], "biasBA": bias[b][a],
          "surrenderAB": surrender[a][b], "surrenderBA": surrender[b][a],
          "contested": contested[a][b], "netFlow": netFlow
        })
      if bias[a][b] > DumpBias * bb:
        flaggedNode.add(%*{
          "a": a, "b": b, "flag": "dump-" & $a & "-to-" & $b,
          "biasAB": bias[a][b], "biasBA": bias[b][a],
          "surrenderAB": surrender[a][b], "surrenderBA": surrender[b][a],
          "contested": contested[a][b], "netFlow": netFlow
        })
      if bias[b][a] > DumpBias * bb:
        flaggedNode.add(%*{
          "a": b, "b": a, "flag": "dump-" & $b & "-to-" & $a,
          "biasAB": bias[b][a], "biasBA": bias[a][b],
          "surrenderAB": surrender[b][a], "surrenderBA": surrender[a][b],
          "contested": contested[a][b], "netFlow": -netFlow
        })

  contestedValues.sort()
  let median =
    if contestedValues.len == 0: 0
    else: contestedValues[contestedValues.len div 2]
  %*{
    "pairs": pairsNode,
    "flagged": flaggedNode,
    "power": {
      "hands": hands.len,
      "contestedMin": (
        if contestedValues.len == 0: 0 else: contestedValues[0]),
      "contestedMedian": median,
      "equitySamples": samples
    }
  }
