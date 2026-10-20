## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "cosino-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc introduction*(selection: PromptSelection, name, game, venue: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & name & ", a cog playing " & game & " at the Cosino " & venue & "."
  of pvPlain: "You play " & game & " as the cog " & name & " at the Cosino " & venue & "."
  of pvNumbered: "Your cog: " & name & ". Game: " & game & ". Venue: the Cosino " & venue & "."
  of pvQuestions: "Who are you? The cog " & name & ". What are you playing? " & game & " at the Cosino " & venue & "."
  of pvReordered: "At the Cosino " & venue & ", you are the cog " & name & " playing " & game & "."
  of pvHeldoutBriefing: "Take the role of " & name & ", a cog at the Cosino " & venue & " playing " & game & "."
  of pvHeldoutReference: "Player reference: cog " & name & "; game " & game & "; venue the Cosino " & venue & "."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc matchBriefing*(selection: PromptSelection, stack: int, chipRace: bool): string =
  let race = [
    "- Every seat bought in ONCE for {stack} chips. Stacks carry from hand to hand,\n  a seat that loses its last chip is OUT for good (no rebuys), and your score is your final\n  CHIP SHARE — so protecting a short stack counts as much as building a tower.\n",
    "Each seat buys in once with {stack} chips. Stacks persist between hands. Losing your last chip eliminates you permanently; there are no rebuys. Your score is final chip share, so preserving a short stack counts as much as building a tower.\n",
    "Match accounting:\n1. One buy-in of {stack} chips per seat.\n2. Stacks carry between hands.\n3. Zero chips means permanent elimination, without rebuys.\n4. Final chip share determines your score; protecting a short stack counts as much as building a tower.\n",
    "Do stacks reset? No: every seat buys in once for {stack} chips and carries its stack between hands. Can a busted seat return? No, losing the last chip is final and there are no rebuys. What scores? Final chip share; preserving a short stack counts as much as building a tower.\n",
    "Score by final chip share: protecting a short stack matters as much as building a tower. Every seat starts with one {stack}-chip buy-in. Carry stacks between hands; a seat losing its last chip is out permanently, with no rebuys.\n",
    "Chip-race briefing: each seat buys in once for {stack} chips. Preserve the stack across hands; losing all chips ends that seat's game, with no rebuy. Final chip share is the score, so protecting a short stack counts as much as building a tower.\n",
    "Chip-race reference: starting buy-in {stack}, once per seat; stacks persist between hands; last chip lost = permanent elimination; no rebuys. Score = final chip share. Protecting a short stack counts as much as building a tower.\n"
  ]
  let ladder = [
    "- Every hand starts with both/all seats on {stack} chips. Your score is your\n  cumulative NET chips across the match, so a chip saved counts exactly as much as a chip won.\n",
    "Every hand resets all seats to {stack} chips. Your score accumulates net chips over the match; saving one chip is worth exactly as much as winning one.\n",
    "Match accounting:\n1. Every hand starts all seats on {stack} chips.\n2. Score is cumulative net chips for the match.\n3. A chip saved counts exactly as much as a chip won.\n",
    "What stacks start a hand? All seats start every hand with {stack} chips. What is your score? Net chips accumulated across the match. Is saving a chip useful? It counts exactly as much as winning one.\n",
    "Maximize cumulative net chips across the match: saving a chip counts exactly as much as winning one. All seats start each new hand with {stack} chips.\n",
    "Ladder briefing: all seats begin every hand with {stack} chips. Accumulate net chips across the match. A saved chip and a won chip contribute equally.\n",
    "Ladder reference: all-seat starting stack {stack}, reset each hand. Match score: cumulative net chips. Value equivalence: one saved chip equals one won chip.\n"
  ]
  let conduct = [
    "- Table talk is public and free. Bluff, needle and mislead — but your cards stay secret until\n  showdown.\n- Pick exactly one action from the legal list you are given, with an amount inside the stated\n  range. An illegal answer is replaced by a house baseline move, which is never what you want.\n\n",
    "Table talk is public and free: bluff, needle, and mislead while keeping cards secret until showdown. Choose exactly one listed legal action and keep its amount within the stated range. An illegal answer is replaced by a house baseline move, which you do not want.\n\n",
    "Table conduct:\n1. Talk is public and free; bluff, needle, and mislead.\n2. Your cards stay secret until showdown.\n3. Select exactly one listed legal action, with an amount in the stated range.\n4. Illegal answers trigger an unwanted house baseline move.\n\n",
    "Can you talk? Yes, publicly and for free: bluff, needle, and mislead. When are your cards revealed? At showdown. What action may you choose? Exactly one from the supplied legal list, with an amount in range. What if it is illegal? An unwanted house baseline move replaces it.\n\n",
    "Choose exactly one action from the legal list and an amount within its range; otherwise an unwanted house baseline move replaces your answer. Table talk is public and free, so bluff, needle, and mislead. Cards remain secret until showdown.\n\n",
    "Table briefing: talk publicly at no cost; bluff, needle, and mislead, with cards hidden until showdown. Select one legal listed action and a permitted amount. Avoid illegal answers, which are replaced by an unwanted house baseline move.\n\n",
    "Conduct reference: table talk public/free; bluffing, needling, misleading allowed; cards secret until showdown. Action contract: exactly one listed legal action, amount in range. Illegal answer: unwanted house baseline substitution.\n\n"
  ]
  let index = ord(selection.selectedVariant)
  (if chipRace: race[index] else: ladder[index]).replace("{stack}", $stack) & conduct[index]
