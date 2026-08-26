## Exact best response and exploitability for the calibration rungs.
##
## Kuhn (6 deals, 12 information sets) and Leduc (30 private deals x 4 board
## cards, a few hundred information sets) are small enough to enumerate whole.
## No sampling, no CFR: the best-response value against a fixed opponent is
## computed by backward induction over counterfactual reach probabilities.
##
## The exploitability reported for a seat uses the duplicate framing:
##
##   v_i = 1/2 [ u0(s_i^0, BR1(s_i^0)) + u1(BR0(s_i^1), s_i^1) ]
##   exploitability_i = -v_i, in chips per hand, always >= 0
##
## The positional value of the game cancels in the average, so this needs no
## precomputed game value and works for Leduc, whose value is not round.

import std/[algorithm, math, strutils, tables]

export tables

type
  CalibVariant* = enum
    cvKuhn = "kuhn"
    cvLeduc = "leduc"

  Act* = enum
    aFold = "fold"
    aCheckCall = "check-call"
    aBetRaise = "bet-raise"

  Strategy* = Table[string, seq[float]]
  ActionCounts* = Table[string, seq[int]]

  CalibResult* = object
    exploitability*: float
    coverage*: float
    fill*: string
    decisions*: int

  BetState = object
    hist*: string
    round*: int
    roundLen*: int
    wagers*: int
    committed*: array[2, int]
    roundBet*: array[2, int]
    toAct*: int
    folded*: int
    finished*: bool

const
  KuhnRanks* = [9, 10, 11]           ## J, Q, K in the 0..12 rank encoding
  LeducRanks* = [9, 9, 10, 10, 11, 11]
  KuhnAlpha* = 1.0 / 6.0

proc actionLetter*(act: Act): string =
  case act
  of aFold: "f"
  of aCheckCall: "c"
  of aBetRaise: "r"

proc deckRanks*(variant: CalibVariant): seq[int] =
  case variant
  of cvKuhn: @KuhnRanks
  of cvLeduc: @LeducRanks

proc roundCount(variant: CalibVariant): int =
  case variant
  of cvKuhn: 1
  of cvLeduc: 2

proc wagerCap(variant: CalibVariant): int =
  case variant
  of cvKuhn: 1
  of cvLeduc: 2

proc betSize(variant: CalibVariant, round: int): int =
  case variant
  of cvKuhn: 1
  of cvLeduc: (if round == 0: 2 else: 4)

proc initBetState(): BetState =
  ## Both seats ante 1; the antes are dead money, so nothing is owed to open.
  BetState(committed: [1, 1], folded: -1)

proc legalOf(variant: CalibVariant, state: BetState): seq[Act] =
  let target = max(state.roundBet[0], state.roundBet[1])
  if state.roundBet[state.toAct] < target:
    result = @[aFold, aCheckCall]
  else:
    result = @[aCheckCall]
  if state.wagers < wagerCap(variant):
    result.add(aBetRaise)

proc applyAct(variant: CalibVariant, state: BetState, act: Act): BetState =
  result = state
  let actor = state.toAct
  case act
  of aFold:
    result.folded = actor
    result.finished = true
    result.hist.add("f")
    return
  of aCheckCall:
    let target = max(state.roundBet[0], state.roundBet[1])
    result.committed[actor] += target - state.roundBet[actor]
    result.roundBet[actor] = target
    result.hist.add("c")
  of aBetRaise:
    let target = max(state.roundBet[0], state.roundBet[1]) +
      betSize(variant, state.round)
    result.committed[actor] += target - state.roundBet[actor]
    result.roundBet[actor] = target
    inc result.wagers
    result.hist.add("r")
  inc result.roundLen
  result.toAct = 1 - actor
  if result.roundLen >= 2 and act == aCheckCall:
    ## The round is settled.
    if state.round + 1 >= roundCount(variant):
      result.finished = true
    else:
      inc result.round
      result.roundLen = 0
      result.wagers = 0
      result.roundBet = [0, 0]
      ## OpenSpiel's Leduc does not switch the first actor between rounds.
      result.toAct = 0
      result.hist.add("/")

proc stateFromHistory*(variant: CalibVariant, hist: string): BetState =
  result = initBetState()
  for letter in hist:
    if letter == '/':
      continue
    let act =
      case letter
      of 'f': aFold
      of 'c': aCheckCall
      of 'r': aBetRaise
      else: raise newException(ValueError, "bad history letter: " & $letter)
    result = applyAct(variant, result, act)

proc legalActions*(variant: CalibVariant, hist: string): seq[Act] =
  legalOf(variant, stateFromHistory(variant, hist))

proc infosetKey*(position, cardRank, boardRank: int, hist: string): string =
  $position & "|" & $cardRank & "|" & $boardRank & "|" & hist

proc handRank(variant: CalibVariant, cardRank, boardRank: int): int =
  case variant
  of cvKuhn: 1000 + cardRank
  of cvLeduc:
    if boardRank == cardRank: 2000 + cardRank else: 1000 + cardRank

proc payoff(variant: CalibVariant, state: BetState,
    rank0, rank1: int): array[2, float] =
  if state.folded >= 0:
    let loss = state.committed[state.folded].float
    result[state.folded] = -loss
    result[1 - state.folded] = loss
    return
  let stake = state.committed[0].float
  if rank0 > rank1:
    result = [stake, -stake]
  elif rank1 > rank0:
    result = [-stake, stake]
  else:
    result = [0.0, 0.0]

proc uniformProbs(count: int): seq[float] =
  result = newSeq[float](count)
  for index in 0 ..< count:
    result[index] = 1.0 / count.float

proc probsFor(strategy: Strategy, key: string, legal: seq[Act]): seq[float] =
  if strategy.hasKey(key):
    let stored = strategy[key]
    if stored.len == legal.len:
      var total = 0.0
      for value in stored:
        total += value
      if total > 1e-12:
        result = newSeq[float](legal.len)
        for index, value in stored:
          result[index] = value / total
        return
  uniformProbs(legal.len)

# ---- Tree evaluation --------------------------------------------------------

proc treeValue(
  variant: CalibVariant,
  ranks: seq[int],
  cards: array[2, int],
  board: int,
  state: BetState,
  brPlayer: int,
  opp: Strategy,
  brPolicy: Table[string, int]
): float =
  ## Expected chips for `brPlayer` from this node, with `brPlayer` following
  ## `brPolicy` and the other seat following `opp`. `brPlayer < 0` means both
  ## seats follow `opp` (a plain expected-value evaluation) and the value is
  ## returned for position 0.
  let valueFor = if brPlayer < 0: 0 else: brPlayer
  if state.finished:
    let boardRank = if board >= 0: ranks[board] else: -1
    return payoff(variant, state,
      handRank(variant, ranks[cards[0]], boardRank),
      handRank(variant, ranks[cards[1]], boardRank))[valueFor]
  if variant == cvLeduc and state.round == 1 and board < 0:
    ## Chance: the public board card, uniform over the remaining deck.
    var total = 0.0
    var count = 0
    for index in 0 ..< ranks.len:
      if index == cards[0] or index == cards[1]:
        continue
      inc count
      total += treeValue(variant, ranks, cards, index, state, brPlayer, opp,
        brPolicy)
    return total / count.float
  let legal = legalOf(variant, state)
  let key = infosetKey(state.toAct, ranks[cards[state.toAct]],
    (if board >= 0: ranks[board] else: -1), state.hist)
  if brPlayer >= 0 and state.toAct == brPlayer:
    let choice = brPolicy.getOrDefault(key, 0)
    let act = legal[min(max(choice, 0), legal.high)]
    return treeValue(variant, ranks, cards, board,
      applyAct(variant, state, act), brPlayer, opp, brPolicy)
  let probs = probsFor(opp, key, legal)
  for index, act in legal:
    if probs[index] <= 0.0:
      continue
    result += probs[index] * treeValue(variant, ranks, cards, board,
      applyAct(variant, state, act), brPlayer, opp, brPolicy)

type
  BrNode = object
    cards: array[2, int]
    board: int
    state: BetState
    reach: float

proc collect(
  variant: CalibVariant,
  ranks: seq[int],
  cards: array[2, int],
  board: int,
  state: BetState,
  brPlayer: int,
  opp: Strategy,
  reach: float,
  nodes: var Table[string, seq[BrNode]]
) =
  ## Enumerates every best-response decision node with its counterfactual
  ## reach (chance x opponent), grouped by information set.
  if state.finished:
    return
  if variant == cvLeduc and state.round == 1 and board < 0:
    var count = 0
    for index in 0 ..< ranks.len:
      if index != cards[0] and index != cards[1]:
        inc count
    for index in 0 ..< ranks.len:
      if index == cards[0] or index == cards[1]:
        continue
      collect(variant, ranks, cards, index, state, brPlayer, opp,
        reach / count.float, nodes)
    return
  let legal = legalOf(variant, state)
  let key = infosetKey(state.toAct, ranks[cards[state.toAct]],
    (if board >= 0: ranks[board] else: -1), state.hist)
  if state.toAct == brPlayer:
    if not nodes.hasKey(key):
      nodes[key] = @[]
    nodes[key].add(BrNode(cards: cards, board: board, state: state,
      reach: reach))
    for act in legal:
      collect(variant, ranks, cards, board, applyAct(variant, state, act),
        brPlayer, opp, reach, nodes)
    return
  let probs = probsFor(opp, key, legal)
  for index, act in legal:
    if probs[index] <= 0.0:
      continue
    collect(variant, ranks, cards, board, applyAct(variant, state, act),
      brPlayer, opp, reach * probs[index], nodes)

proc actionDepth(hist: string): int =
  for letter in hist:
    if letter != '/':
      inc result

proc bestResponseValue*(variant: CalibVariant, brPlayer: int,
    opp: Strategy): float =
  ## Expected chips per hand for `brPlayer` playing an exact best response to
  ## `opp`. Exact: every information set is enumerated and every node in it is
  ## weighted by its counterfactual reach.
  let ranks = deckRanks(variant)
  var nodes = initTable[string, seq[BrNode]]()
  var deals: seq[array[2, int]]
  for first in 0 ..< ranks.len:
    for second in 0 ..< ranks.len:
      if first != second:
        deals.add([first, second])
  let dealProb = 1.0 / deals.len.float
  for deal in deals:
    collect(variant, ranks, deal, -1, initBetState(), brPlayer, opp, dealProb,
      nodes)

  ## Deeper information sets first: the value of an action at a node depends
  ## only on strictly deeper best-response decisions, which are fixed by then.
  var keys: seq[string]
  for key in nodes.keys:
    keys.add(key)
  keys.sort(proc (a, b: string): int =
    let da = actionDepth(a.split('|')[3])
    let db = actionDepth(b.split('|')[3])
    if da != db: cmp(db, da) else: cmp(a, b))

  var brPolicy = initTable[string, int]()
  for key in keys:
    let group = nodes[key]
    let legal = legalOf(variant, group[0].state)
    var bestIndex = 0
    var bestValue = -Inf
    for index, act in legal:
      var total = 0.0
      for node in group:
        if node.reach <= 0.0:
          continue
        total += node.reach * treeValue(variant, ranks, node.cards, node.board,
          applyAct(variant, node.state, act), brPlayer, opp, brPolicy)
      if total > bestValue:
        bestValue = total
        bestIndex = index
    brPolicy[key] = bestIndex

  for deal in deals:
    result += dealProb * treeValue(variant, ranks, deal, -1, initBetState(),
      brPlayer, opp, brPolicy)

proc gameValue*(variant: CalibVariant, strategy: Strategy): float =
  ## u0 when both seats play `strategy` (which carries both positions' keys).
  let ranks = deckRanks(variant)
  var deals: seq[array[2, int]]
  for first in 0 ..< ranks.len:
    for second in 0 ..< ranks.len:
      if first != second:
        deals.add([first, second])
  let dealProb = 1.0 / deals.len.float
  let empty = initTable[string, int]()
  for deal in deals:
    result += dealProb * treeValue(variant, ranks, deal, -1, initBetState(),
      -1, strategy, empty)

proc exploitability*(variant: CalibVariant, strategy: Strategy): float =
  ## Chips per hand a perfect exploiter takes from a seat that plays
  ## `strategy` at BOTH positions. Zero exactly when the strategy is
  ## unexploitable at both.
  0.5 * (bestResponseValue(variant, 1, strategy) +
    bestResponseValue(variant, 0, strategy))

# ---- Information-set enumeration -------------------------------------------

proc walkInfosets(
  variant: CalibVariant,
  ranks: seq[int],
  cards: array[2, int],
  board: int,
  state: BetState,
  found: var OrderedTable[string, seq[Act]]
) =
  if state.finished:
    return
  if variant == cvLeduc and state.round == 1 and board < 0:
    for index in 0 ..< ranks.len:
      if index == cards[0] or index == cards[1]:
        continue
      walkInfosets(variant, ranks, cards, index, state, found)
    return
  let legal = legalOf(variant, state)
  let key = infosetKey(state.toAct, ranks[cards[state.toAct]],
    (if board >= 0: ranks[board] else: -1), state.hist)
  if not found.hasKey(key):
    found[key] = legal
  for act in legal:
    walkInfosets(variant, ranks, cards, board, applyAct(variant, state, act),
      found)

proc allInfosets*(variant: CalibVariant): OrderedTable[string, seq[Act]] =
  ## Every reachable information set of the game, for both positions.
  result = initOrderedTable[string, seq[Act]]()
  let ranks = deckRanks(variant)
  for first in 0 ..< ranks.len:
    for second in 0 ..< ranks.len:
      if first != second:
        walkInfosets(variant, ranks, [first, second], -1, initBetState(),
          result)

proc keyParts*(key: string): tuple[position, card, board: int, hist: string] =
  let parts = key.split('|')
  (parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2]), parts[3])

# ---- Named strategy tables --------------------------------------------------

proc put(strategy: var Strategy, key: string, legal: seq[Act],
    weights: openArray[(Act, float)]) =
  var probs = newSeq[float](legal.len)
  for (act, weight) in weights:
    for index, candidate in legal:
      if candidate == act:
        probs[index] = weight
  strategy[key] = probs

proc nashKuhn*(alpha: float): Strategy =
  ## The alpha-family Kuhn equilibrium. alpha in [0, 1/3]; the design fields
  ## alpha = 1/6 as the `house` baseline.
  result = initTable[string, seq[float]]()
  for key, legal in allInfosets(cvKuhn):
    let (position, card, _, hist) = keyParts(key)
    let jack = card == 9
    let queen = card == 10
    let king = card == 11
    if position == 0 and hist.len == 0:
      let betProb = if jack: alpha elif queen: 0.0 else: 3.0 * alpha
      result.put(key, legal,
        [(aCheckCall, 1.0 - betProb), (aBetRaise, betProb)])
    elif position == 0 and hist == "cr":
      let callProb = if jack: 0.0 elif queen: alpha + 1.0 / 3.0 else: 1.0
      result.put(key, legal, [(aFold, 1.0 - callProb), (aCheckCall, callProb)])
    elif position == 1 and hist == "c":
      let betProb = if jack: 1.0 / 3.0 elif queen: 0.0 else: 1.0
      result.put(key, legal,
        [(aCheckCall, 1.0 - betProb), (aBetRaise, betProb)])
    elif position == 1 and hist == "r":
      let callProb = if jack: 0.0 elif queen: 1.0 / 3.0 else: 1.0
      result.put(key, legal, [(aFold, 1.0 - callProb), (aCheckCall, callProb)])
    else:
      result[key] = uniformProbs(legal.len)

proc rockKuhn*(): Strategy =
  ## Deterministic and deliberately exploitable: bet iff K, call iff K.
  result = initTable[string, seq[float]]()
  for key, legal in allInfosets(cvKuhn):
    let (_, card, _, _) = keyParts(key)
    let king = card == 11
    if aFold in legal:
      result.put(key, legal,
        [(aFold, if king: 0.0 else: 1.0), (aCheckCall, if king: 1.0 else: 0.0)])
    else:
      result.put(key, legal,
        [(aCheckCall, if king: 0.0 else: 1.0),
         (aBetRaise, if king: 1.0 else: 0.0)])

proc facingWagers(variant: CalibVariant, hist: string): int =
  ## Wagers the actor is facing in the current round.
  let state = stateFromHistory(variant, hist)
  if state.roundBet[state.toAct] < max(state.roundBet[0], state.roundBet[1]):
    state.wagers
  else:
    0

proc houseLeduc*(): Strategy =
  ## The design's `house` Leduc rule table, with seeded mixing expressed as
  ## the frequencies it mixes at.
  result = initTable[string, seq[float]]()
  for key, legal in allInfosets(cvLeduc):
    let (_, card, board, hist) = keyParts(key)
    let round = if '/' in hist: 1 else: 0
    let faced = facingWagers(cvLeduc, hist)
    let jack = card == 9
    let queen = card == 10
    let king = card == 11
    let paired = board >= 0 and board == card
    if round == 0:
      case faced
      of 0:
        let betProb = if king: 1.0 elif queen: 1.0 / 3.0 else: 0.0
        result.put(key, legal,
          [(aCheckCall, 1.0 - betProb), (aBetRaise, betProb)])
      of 1:
        if king and aBetRaise in legal:
          result.put(key, legal, [(aBetRaise, 1.0)])
        elif king or queen:
          result.put(key, legal, [(aCheckCall, 1.0)])
        else:
          result.put(key, legal, [(aFold, 1.0)])
      else:
        if king:
          result.put(key, legal, [(aCheckCall, 1.0)])
        else:
          result.put(key, legal, [(aFold, 1.0)])
    else:
      case faced
      of 0:
        let betProb =
          if paired: 1.0
          elif king: 0.5
          else: 0.0
        result.put(key, legal,
          [(aCheckCall, 1.0 - betProb), (aBetRaise, betProb)])
      of 1:
        if paired and aBetRaise in legal:
          result.put(key, legal, [(aBetRaise, 1.0)])
        elif paired or king or (queen and board == 9):
          result.put(key, legal, [(aCheckCall, 1.0)])
        else:
          result.put(key, legal, [(aFold, 1.0)])
      else:
        if paired or king:
          result.put(key, legal, [(aCheckCall, 1.0)])
        else:
          result.put(key, legal, [(aFold, 1.0)])

proc rockLeduc*(): Strategy =
  ## Never opens a wager unless paired with the board; facing any wager, calls
  ## iff paired or holding K.
  result = initTable[string, seq[float]]()
  for key, legal in allInfosets(cvLeduc):
    let (_, card, board, hist) = keyParts(key)
    let faced = facingWagers(cvLeduc, hist)
    let paired = board >= 0 and board == card
    let king = card == 11
    if faced == 0:
      if paired and aBetRaise in legal:
        result.put(key, legal, [(aBetRaise, 1.0)])
      else:
        result.put(key, legal, [(aCheckCall, 1.0)])
    else:
      if paired or king:
        result.put(key, legal, [(aCheckCall, 1.0)])
      else:
        result.put(key, legal, [(aFold, 1.0)])

proc uniformStrategy*(variant: CalibVariant): Strategy =
  result = initTable[string, seq[float]]()
  for key, legal in allInfosets(variant):
    result[key] = uniformProbs(legal.len)

proc alwaysFold*(variant: CalibVariant): Strategy =
  ## Folds to any wager and never opens one — the trivial punching bag.
  result = initTable[string, seq[float]]()
  for key, legal in allInfosets(variant):
    if aFold in legal:
      result.put(key, legal, [(aFold, 1.0)])
    else:
      result.put(key, legal, [(aCheckCall, 1.0)])

proc fillName*(variant: CalibVariant): string =
  case variant
  of cvKuhn: "nash"
  of cvLeduc: "uniform"

proc fillStrategy*(variant: CalibVariant): Strategy =
  ## Kuhn fills unvisited information sets with the known Nash strategy at
  ## alpha = 1/6; Leduc has no closed form, so it fills uniformly.
  case variant
  of cvKuhn: nashKuhn(KuhnAlpha)
  of cvLeduc: uniformStrategy(cvLeduc)

proc empiricalStrategy*(variant: CalibVariant, observed: ActionCounts):
    tuple[strategy: Strategy, coverage: float, visited: int, total: int] =
  ## Observed frequencies where the seat actually played, the declared fill
  ## everywhere else, and the fraction of reachable information sets it
  ## visited — so a thin sample is visible rather than hidden.
  let fill = fillStrategy(variant)
  var strategy = initTable[string, seq[float]]()
  var visited = 0
  var total = 0
  for key, legal in allInfosets(variant):
    inc total
    var counted = 0
    if observed.hasKey(key):
      for value in observed[key]:
        counted += value
    if counted > 0 and observed[key].len == legal.len:
      inc visited
      var probs = newSeq[float](legal.len)
      for index, value in observed[key]:
        probs[index] = value.float / counted.float
      strategy[key] = probs
    else:
      strategy[key] = fill.getOrDefault(key, uniformProbs(legal.len))
  (strategy, visited.float / max(total, 1).float, visited, total)

proc exploitabilityOf*(variant: CalibVariant, observed: ActionCounts,
    decisions: int): CalibResult =
  let (strategy, coverage, _, _) = empiricalStrategy(variant, observed)
  CalibResult(
    exploitability: exploitability(variant, strategy),
    coverage: coverage,
    fill: fillName(variant),
    decisions: decisions
  )
