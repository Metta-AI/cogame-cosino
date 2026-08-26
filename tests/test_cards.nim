## Hand evaluation and the calibration-rung decks.

import std/[strutils, unicode, unittest]
import cosino/[cards, types]

suite "hand evaluator":
  test "category ladder":
    let hands = [
      ("2c 3d 5h 9s Ks", HandHighCard),
      ("2c 2d 5h 9s Ks", HandPair),
      ("2c 2d 5h 5s Ks", HandTwoPair),
      ("2c 2d 2h 9s Ks", HandTrips),
      ("2c 3d 4h 5s 6s", HandStraight),
      ("2s 5s 9s Js Ks", HandFlush),
      ("2c 2d 2h Ks Kd", HandFullHouse),
      ("2c 2d 2h 2s Kd", HandQuads),
      ("2s 3s 4s 5s 6s", HandStraightFlush)
    ]
    for index in 0 ..< hands.len - 1:
      check eval5(parseCards(hands[index][0])) <
        eval5(parseCards(hands[index + 1][0]))
    for (text, category) in hands:
      check handCategory(eval5(parseCards(text))) == category

  test "kickers decide":
    check eval5(parseCards("As Ad 9c 5d 3h")) >
      eval5(parseCards("Ks Kd Qc Jd 9h"))
    check eval5(parseCards("As Ad Kc 5d 3h")) >
      eval5(parseCards("Ah Ac Qc Jd 9h"))
    check eval5(parseCards("As Ks Qs Js 2s")) >
      eval5(parseCards("Ah Kh Qh Th 3h"))

  test "the wheel is the lowest straight":
    let wheel = eval5(parseCards("As 2d 3h 4c 5s"))
    check handCategory(wheel) == HandStraight
    check wheel < eval5(parseCards("2d 3h 4c 5s 6d"))
    check eval5(parseCards("Ts Jd Qh Kc As")) >
      eval5(parseCards("9s Td Jh Qc Ks"))

  test "seven cards use the best five":
    let rank = evalBest(parseCards("Ah Kh 2h 5h 9h 2c 2d"))
    check handCategory(rank) == HandFlush
    let boardPlays = evalBest(parseCards("Ts Jd Qh Kc Ad 2c 2d"))
    check handCategory(boardPlays) == HandStraight
    check describeRank(evalBest(parseCards("As Ks Qs Js Ts 2c 3d"))) ==
      "a royal flush"

  test "cards round-trip text":
    for card in 0 ..< 52:
      check parseCard(cardText(card)) == card

suite "calibration decks":
  test "the kuhn deck is exactly J-Q-K of spades":
    let deck = kuhnDeck()
    check deck.len == 3
    check deck == @[39, 43, 47]
    for card in deck:
      check card.suit == 3
    var ranks: seq[int]
    for card in deck:
      ranks.add(card.rank)
    check ranks == @[9, 10, 11]

  test "the leduc deck is J-Q-K in two suits":
    let deck = leducDeck()
    check deck.len == 6
    check deck == @[39, 43, 47, 38, 42, 46]
    var spades, hearts: seq[int]
    for card in deck:
      if card.suit == 3: spades.add(card.rank)
      elif card.suit == 2: hearts.add(card.rank)
    check spades == @[9, 10, 11]
    check hearts == @[9, 10, 11]
    ## Every card in the deck is distinct.
    for i in 0 ..< deck.len:
      for j in i + 1 ..< deck.len:
        check deck[i] != deck[j]

  test "leducRank: pair beats high card, J < Q < K, equal ranks split":
    let jack = 39      ## Js
    let queen = 43     ## Qs
    let king = 47      ## Ks
    let jackHearts = 38
    ## Pair beats any unpaired hand, whatever the ranks.
    check leducRank(jack, jackHearts) > leducRank(king, -1)
    check leducRank(jack, jackHearts) > leducRank(king, 42)
    ## Unpaired hands order J < Q < K.
    check leducRank(jack, -1) < leducRank(queen, -1)
    check leducRank(queen, -1) < leducRank(king, -1)
    check leducRank(jack, 42) < leducRank(queen, 42)
    ## Equal ranks are a split, paired or not.
    check leducRank(jack, -1) == leducRank(jackHearts, -1)
    check leducRank(queen, 42) == leducRank(42, queen)
    ## Higher pairs beat lower pairs.
    check leducRank(king, 46) > leducRank(queen, 42)

suite "rune truncation":
  test "never splits a multi-byte rune":
    let emoji = "\u{1F0A1}".repeat(400)   ## the ace of spades, 4 bytes each
    let cut = truncateRunes(emoji, MaxSayLen)
    check cut.runeLen == MaxSayLen
    check cut.validateUtf8() == -1
    check cut.endsWith("\u2026")

  test "short strings pass through untouched":
    check truncateRunes("all in", 160) == "all in"
    check truncateRunes("", 160) == ""
    check truncateRunes("abc", 0) == ""

  test "the cut lands on a rune boundary for mixed text":
    let mixed = "raise \u00e9\u00e8\u00ea " & "\u4f60\u597d".repeat(200)
    for cap in [2, 7, 16, 160, 200]:
      let cut = truncateRunes(mixed, cap)
      check cut.validateUtf8() == -1
      check cut.runeLen <= cap
