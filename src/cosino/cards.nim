## Cards and hand evaluation for Cosino. Pure: no IO, no globals.
##
## A card is an int 0..51: `rank = card div 4` (0 = deuce … 12 = ace),
## `suit = card mod 4` (clubs, diamonds, hearts, spades). A hand rank is a
## packed int where a bigger value always beats a smaller one: the category
## in the high bits, then the five deciding ranks in significance order,
## one nibble each — so ties compare correctly all the way down to the
## last kicker.

import std/[random, strutils], types

const
  RankChars* = "23456789TJQKA"
  SuitChars* = "cdhs"
  SuitGlyphs*: array[4, string] = ["♣", "♦", "♥", "♠"]

  ## Hand categories, high bits of a packed rank.
  HandHighCard* = 0
  HandPair* = 1
  HandTwoPair* = 2
  HandTrips* = 3
  HandStraight* = 4
  HandFlush* = 5
  HandFullHouse* = 6
  HandQuads* = 7
  HandStraightFlush* = 8

  CategoryNames*: array[9, string] = [
    "high card", "a pair", "two pair", "three of a kind", "a straight",
    "a flush", "a full house", "four of a kind", "a straight flush"
  ]

proc rank*(card: int): int = card div 4
proc suit*(card: int): int = card mod 4

proc cardText*(card: int): string =
  ## "As", "Td", "2c" — rank char then suit char.
  $RankChars[card.rank] & $SuitChars[card.suit]

proc cardPretty*(card: int): string =
  $RankChars[card.rank] & SuitGlyphs[card.suit]

proc cardsText*(cards: seq[int]): string =
  var parts: seq[string]
  for card in cards:
    parts.add(cardText(card))
  parts.join(" ")

proc parseCard*(text: string): int =
  ## Inverse of cardText, for tests and fixtures.
  if text.len != 2:
    raise newException(CosinoError, "bad card: " & text)
  let rankIndex = RankChars.find(text[0])
  let suitIndex = SuitChars.find(text[1])
  if rankIndex < 0 or suitIndex < 0:
    raise newException(CosinoError, "bad card: " & text)
  rankIndex * 4 + suitIndex

proc parseCards*(text: string): seq[int] =
  for part in text.splitWhitespace():
    result.add(parseCard(part))

proc shuffledDeck*(rng: var Rand): seq[int] =
  for card in 0 ..< 52:
    result.add(card)
  rng.shuffle(result)

proc packRank(category: int, ranks: openArray[int]): int =
  ## category, then up to five deciding ranks, one nibble each,
  ## most significant first. Missing trailing kickers pack as zero, which
  ## is correct: a five-card hand never compares against a different count.
  result = category shl 20
  for index in 0 ..< 5:
    let value = if index < ranks.len: ranks[index] else: 0
    result = result or (value shl (16 - 4 * index))

proc straightHigh(rankSet: set[0 .. 12]): int =
  ## Highest straight top rank in the set, or -1. The wheel (A-2-3-4-5)
  ## counts with the five high.
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

proc eval5*(cards: openArray[int]): int =
  ## Packed rank of exactly five cards.
  assert cards.len == 5
  var counts: array[13, int]
  var rankSet: set[0 .. 12]
  var flush = true
  for card in cards:
    inc counts[card.rank]
    rankSet.incl(card.rank)
    if card.suit != cards[0].suit:
      flush = false
  let straight = straightHigh(rankSet)

  if flush and straight >= 0:
    return packRank(HandStraightFlush, [straight])

  ## Group ranks by multiplicity, each group sorted high-first.
  var quads, trips, pairs, singles: seq[int]
  for rankValue in countdown(12, 0):
    case counts[rankValue]
    of 4: quads.add(rankValue)
    of 3: trips.add(rankValue)
    of 2: pairs.add(rankValue)
    of 1: singles.add(rankValue)
    else: discard

  if quads.len == 1:
    return packRank(HandQuads, [quads[0], singles[0]])
  if trips.len == 1 and pairs.len == 1:
    return packRank(HandFullHouse, [trips[0], pairs[0]])
  if flush:
    return packRank(HandFlush, singles)
  if straight >= 0:
    return packRank(HandStraight, [straight])
  if trips.len == 1:
    return packRank(HandTrips, [trips[0], singles[0], singles[1]])
  if pairs.len == 2:
    return packRank(HandTwoPair, [pairs[0], pairs[1], singles[0]])
  if pairs.len == 1:
    return packRank(HandPair, [pairs[0], singles[0], singles[1], singles[2]])
  packRank(HandHighCard, singles)

proc evalBest*(cards: openArray[int]): int =
  ## Best five-card rank from five, six, or seven cards. Twenty-one
  ## combinations at worst; a poker hand evaluates a handful of times per
  ## showdown, so brute force is plenty.
  assert cards.len >= 5 and cards.len <= 7
  if cards.len == 5:
    return eval5(cards)
  var five: array[5, int]
  var chosen = newSeq[int](cards.len)
  for index in 0 ..< cards.len:
    chosen[index] = index
  ## Iterate all 5-subsets via the two indices left out.
  for dropA in 0 ..< cards.len:
    let lastDrop = if cards.len == 7: cards.len else: dropA + 1
    for dropB in dropA + 1 .. lastDrop:
      let dropSecond = if cards.len == 7: dropB else: -1
      var slot = 0
      for index in 0 ..< cards.len:
        if index == dropA or index == dropSecond:
          continue
        if slot < 5:
          five[slot] = cards[index]
          inc slot
      if slot == 5:
        let value = eval5(five)
        if value > result:
          result = value

proc handCategory*(packed: int): int = packed shr 20

proc describeRank*(packed: int): string =
  ## Human line for showdown feeds: "a flush, ace high", "two pair, kings
  ## and fours", …
  let category = packed.handCategory
  proc nibble(index: int): int = (packed shr (16 - 4 * index)) and 0xF
  proc rankName(value: int): string =
    case value
    of 12: "aces"
    of 11: "kings"
    of 10: "queens"
    of 9: "jacks"
    of 8: "tens"
    of 7: "nines"
    of 6: "eights"
    of 5: "sevens"
    of 4: "sixes"
    of 3: "fives"
    of 2: "fours"
    of 1: "threes"
    else: "deuces"
  proc highName(value: int): string =
    let plural = rankName(value)
    if plural == "sixes": "six"
    elif plural.endsWith("s"): plural[0 ..< plural.len - 1]
    else: plural
  case category
  of HandStraightFlush:
    if nibble(0) == 12: "a royal flush"
    else: "a straight flush, " & highName(nibble(0)) & " high"
  of HandQuads: "four " & rankName(nibble(0))
  of HandFullHouse:
    "a full house, " & rankName(nibble(0)) & " full of " & rankName(nibble(1))
  of HandFlush: "a flush, " & highName(nibble(0)) & " high"
  of HandStraight: "a straight, " & highName(nibble(0)) & " high"
  of HandTrips: "three " & rankName(nibble(0))
  of HandTwoPair:
    "two pair, " & rankName(nibble(0)) & " and " & rankName(nibble(1))
  of HandPair: "a pair of " & rankName(nibble(0))
  else: highName(nibble(0)) & " high"
