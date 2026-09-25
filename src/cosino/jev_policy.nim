## Player-side Jev policy over Cosino's general action space.

import std/[json, os, strutils, times]
import curly

var lastCall: float

proc chooseAction*(observation: JsonNode, guidance: string): JsonNode =
  var candidates = newJObject()
  var criteria = newJObject()
  for option in observation["actionSpace"]:
    let kind = option["kind"].getStr()
    if kind in ["bet", "raise"]:
      let low = option["min"].getInt()
      let high = option["max"].getInt()
      let pot = observation["pot"].getInt()
      for amount in [low, high, max(low, min(high, pot div 2)),
          max(low, min(high, pot)), max(low, min(high, pot * 2)),
          low + (high - low) div 2]:
        let label = kind & " " & $amount
        candidates[label] = %*{"kind": kind, "amount": amount}
        criteria[label] = %label
    else:
      candidates[kind] = %*{"kind": kind}
      criteria[kind] = %kind
  if criteria.len == 0:
    raise newException(ValueError, "Jev received no legal actions")

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Cosino Jev has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing Cosino poker. Rank candidate actions for your " &
      "final chip result. " & guidance & "\nYour seat observation:\n" &
      $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose one exact legal action label.",
      "criteria": criteria
    }}
  }
  let elapsed = epochTime() - lastCall
  if lastCall > 0 and elapsed < 2.1:
    sleep(((2.1 - elapsed) * 1000).int)
  lastCall = epochTime()
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 18)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not candidates.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown action")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = candidates[choice]
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "Cosino Jev: action ", result,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
