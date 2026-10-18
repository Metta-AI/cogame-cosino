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
  PromptBankVersion* = "cosino-rules-v1"

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
