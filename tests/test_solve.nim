## Exact best response and exploitability on the calibration rungs.

import std/[math, tables, unittest]
import cosino/solve

suite "kuhn: exact best response":
  test "the Nash strategy reproduces the known game value of -1/18":
    for alpha in [0.0, 1.0 / 6.0, 1.0 / 3.0]:
      check abs(gameValue(cvKuhn, nashKuhn(alpha)) - (-1.0 / 18.0)) < 1e-12

  test "the alpha-family equilibrium is unexploitable":
    for alpha in [0.0, 1.0 / 6.0, 1.0 / 3.0]:
      check exploitability(cvKuhn, nashKuhn(alpha)) < 1e-9

  test "an exploitable strategy measures as exploitable":
    ## `rock` bets and calls only the king: a perfect exploiter takes chips.
    check exploitability(cvKuhn, rockKuhn()) > 0.05
    check exploitability(cvKuhn, uniformStrategy(cvKuhn)) > 0.05

  test "the tree has exactly twelve information sets":
    check allInfosets(cvKuhn).len == 12
    var byPosition = [0, 0]
    for key, _ in allInfosets(cvKuhn):
      let (position, _, board, _) = keyParts(key)
      check board == -1
      inc byPosition[position]
    check byPosition == [6, 6]

  test "best response beats or matches the equilibrium value":
    ## The BR value can never be worse than the Nash value of that seat.
    let nash = nashKuhn(1.0 / 6.0)
    check bestResponseValue(cvKuhn, 1, nash) >= 1.0 / 18.0 - 1e-12
    check bestResponseValue(cvKuhn, 0, nash) >= -1.0 / 18.0 - 1e-12

suite "leduc: exact best response":
  test "best response against always-fold is the trivially computable value":
    ## The punching bag never opens a wager and folds to any bet, so the
    ## exploiter bets round one and collects the opponent's ante, every hand,
    ## from either position: exactly 1 chip.
    let target = alwaysFold(cvLeduc)
    check abs(bestResponseValue(cvLeduc, 0, target) - 1.0) < 1e-9
    check abs(bestResponseValue(cvLeduc, 1, target) - 1.0) < 1e-9

  test "the house table's exploitability is finite, positive and stable":
    let house = houseLeduc()
    let first = exploitability(cvLeduc, house)
    let second = exploitability(cvLeduc, houseLeduc())
    check first > 0.0
    check first < 100.0
    ## Deterministic: the same table measures identically however it is built,
    ## so a seed never moves the number.
    check abs(first - second) < 1e-12
    check exploitability(cvLeduc, rockLeduc()) > 0.0

  test "the tree is a few hundred information sets over two positions":
    let sets = allInfosets(cvLeduc)
    check sets.len > 100
    check sets.len < 1000
    var withBoard = 0
    for key, _ in sets:
      let (_, _, board, _) = keyParts(key)
      if board >= 0:
        inc withBoard
    check withBoard > 0

suite "empirical strategies, fills and coverage":
  test "kuhn fills unvisited infosets with nash, leduc with uniform":
    check fillName(cvKuhn) == "nash"
    check fillName(cvLeduc) == "uniform"
    ## An empty observation is entirely fill, so it measures exactly like the
    ## fill it was built from.
    var none = initTable[string, seq[int]]()
    let kuhnResult = exploitabilityOf(cvKuhn, none, 0)
    check kuhnResult.fill == "nash"
    check kuhnResult.coverage == 0.0
    check kuhnResult.exploitability < 1e-9
    let leducResult = exploitabilityOf(cvLeduc, none, 0)
    check leducResult.fill == "uniform"
    check leducResult.coverage == 0.0
    check abs(leducResult.exploitability -
      exploitability(cvLeduc, uniformStrategy(cvLeduc))) < 1e-12

  test "coverage is reported correctly for a half-visited tree":
    for variant in [cvKuhn, cvLeduc]:
      let sets = allInfosets(variant)
      var observed = initTable[string, seq[int]]()
      var index = 0
      var visited = 0
      for key, legal in sets:
        if index mod 2 == 0:
          var counts = newSeq[int](legal.len)
          counts[0] = 3
          observed[key] = counts
          inc visited
        inc index
      let outcome = exploitabilityOf(variant, observed, visited)
      check outcome.decisions == visited
      check abs(outcome.coverage - visited.float / sets.len.float) < 1e-12
      check abs(outcome.coverage - 0.5) < 0.02

  test "observed counts become frequencies":
    let sets = allInfosets(cvKuhn)
    var observed = initTable[string, seq[int]]()
    for key, legal in sets:
      var counts = newSeq[int](legal.len)
      counts[0] = 1
      counts[legal.high] = 3
      observed[key] = counts
    let (strategy, coverage, visited, total) =
      empiricalStrategy(cvKuhn, observed)
    check coverage == 1.0
    check visited == total
    for key, legal in sets:
      let probs = strategy[key]
      check abs(probs[0] - 0.25) < 1e-12
      check abs(probs[legal.high] - 0.75) < 1e-12

  test "exploitability is never negative":
    ## exploitability = 1/2 (BR1 + BR0) and each BR is at least the Nash value
    ## of that seat, so the sum cannot dip below zero.
    for strategy in [nashKuhn(1.0 / 6.0), rockKuhn(),
        uniformStrategy(cvKuhn), alwaysFold(cvKuhn)]:
      check exploitability(cvKuhn, strategy) >= -1e-12
    for strategy in [houseLeduc(), rockLeduc(), uniformStrategy(cvLeduc),
        alwaysFold(cvLeduc)]:
      check exploitability(cvLeduc, strategy) >= -1e-12
