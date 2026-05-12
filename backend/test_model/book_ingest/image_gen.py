"""Phase 5 — generate illustrations via Azure gpt-image-2.

Two failure modes worth handling differently:

  • Transient (429, 5xx) → exponential backoff via `retry.with_retries`.
  • Content-policy 400 (Azure RAI rejects the prompt) → not retryable
    with the same prompt, but often *recoverable* by rewriting the
    scene description. `generate_image_with_softening` catches that
    case, calls the LLM softener to rephrase, and tries again.

Reader-preference plumbing: every scene prompt is composed as

    <scene description>. <book-wide style>. <reader_preference>. <negative>

so the *user's* taste (e.g. "I like mystical, painterly imagery") steers
the result alongside the per-book style. Empty preference → no-op.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import time

import requests

from .config import config
from .retry import with_retries


_NEGATIVE_GUIDANCE = (
    "no text, no captions, no logos, no watermark, no signatures, "
    "no borders, no frames, no UI elements, no panel grids, "
    "no speech bubbles, no page numbers"
)

# Cinematic framing cues appended to every prompt. Tunes the image
# model toward illustration-as-artwork rather than stock-photo realism.
_CINEMATIC_GUIDANCE = (
    "cinematic composition, deliberate negative space, clear focal "
    "subject, layered foreground / midground / background, atmospheric "
    "depth, intentional light direction, painterly detail"
)

# Composition → (aspect-ratio size, depth-of-field cue) lookup. Sizes
# the gpt-image-2 deployment accepts: 1024x1024 (square),
# 1024x1536 (portrait), 1536x1024 (landscape).
_COMPOSITION_TUNING: dict[str, tuple[str, str]] = {
    "close-up": ("1024x1024", "shallow depth of field, subject fills the frame, expressive face or hands in focus"),
    "medium": ("1024x1024", "balanced framing, subject waist-up, soft background"),
    "wide": ("1536x1024", "subject embedded in setting, environmental storytelling, breathing room around figures"),
    "establishing": ("1536x1024", "sweeping vista or architecture, figures small or absent, sense of scale"),
    "overhead": ("1024x1024", "top-down view, geometric arrangement, pattern of figures and objects"),
    "low-angle": ("1024x1536", "camera looking up, towering subject, dramatic sky or ceiling"),
}

# Fragments that signal Azure's responsible-AI / content-policy filter
# tripped. We match on either the structured error code or the body text
# because the JSON shape isn't always consistent across Azure regions.
_POLICY_KEYWORDS = (
    "content_filter",
    "content_policy",
    "responsiblepolicy",
    "responsible_ai",
    "content management policy",
    "safety system",
    "moderation_blocked",
    "image_generation_user_error",
    "your prompt may contain text",  # Azure's user-friendly variant
)


class ContentPolicyViolation(Exception):
    """Raised when Azure's image API rejects a prompt for content-policy
    reasons (HTTP 400 with a RAI / safety-system code in the body).

    Distinct from a generic 400 so the softening wrapper can catch it
    without swallowing real malformed-request errors."""

    def __init__(self, message: str, *, body: str = ""):
        super().__init__(message)
        self.body = body


def compose_prompt(
    scene: str,
    *,
    style: str | None,
    reader_preference: str | None,
    mood: str | None = None,
    composition: str | None = None,
    time_of_day: str | None = None,
    setting: str | None = None,
    palette_hint: str | None = None,
    base_palette: str | None = None,
    character_refs: list[str] | None = None,
) -> str:
    """Build the full image-gen prompt from a scene + book-wide art direction.

    Layering (most → least specific so the model anchors on the scene
    first and uses the book-wide guidance as background):
      1. scene_text (the moment to depict)
      2. setting (where it happens)
      3. time_of_day + mood (light + emotional register)
      4. character refs from the scout's character_bible
      5. composition + cinematic framing cues
      6. scene-specific palette override OR book-wide base palette
      7. book-wide style string from the scout
      8. reader preference
      9. negative guidance
    """
    parts: list[str] = [scene.strip().rstrip(".")]
    if setting:
        parts.append(f"setting: {setting.strip().rstrip('.')}")
    light_mood: list[str] = []
    if time_of_day:
        light_mood.append(time_of_day.strip().rstrip("."))
    if mood:
        light_mood.append(f"mood: {mood.strip().rstrip('.')}")
    if light_mood:
        parts.append(", ".join(light_mood))
    if character_refs:
        # Each ref is a vivid one-line appearance ("Alice: small girl,
        # long fair hair, blue pinafore…"). Joined with semicolons so
        # the model treats them as separate locked-in descriptions.
        refs_line = "; ".join(r.strip().rstrip(".") for r in character_refs if r and r.strip())
        if refs_line:
            parts.append(f"characters: {refs_line}")
    if composition:
        comp_extra = _COMPOSITION_TUNING.get(composition, (None, None))[1]
        comp_line = f"{composition} shot"
        if comp_extra:
            comp_line = f"{comp_line}, {comp_extra}"
        parts.append(comp_line)
    parts.append(_CINEMATIC_GUIDANCE)
    palette = palette_hint or base_palette
    if palette:
        parts.append(f"palette: {palette.strip().rstrip('.')}")
    if style:
        parts.append(style.strip().rstrip("."))
    if reader_preference:
        parts.append(f"reader preference: {reader_preference.strip().rstrip('.')}")
    parts.append(_NEGATIVE_GUIDANCE)
    return ". ".join(parts)


def size_for_composition(composition: str | None) -> str:
    """Pick the aspect ratio that flatters the composition. Defaults to
    1024x1024 when composition is missing or unknown."""
    if composition and composition in _COMPOSITION_TUNING:
        return _COMPOSITION_TUNING[composition][0]
    return "1024x1024"


def _is_content_policy_400(exc: requests.HTTPError) -> tuple[bool, str]:
    """Return (is_policy_violation, body_text). body_text is captured
    even when the answer is False so callers can log the response."""
    if exc.response is None or exc.response.status_code != 400:
        return False, ""
    body_text = ""
    try:
        body = exc.response.json()
        body_text = json.dumps(body)[:2000]
        # Azure shape: {"error": {"code": "content_filter", "message": "..."}}
        # Sometimes nested: {"error": {"inner_error": {"content_filter_results": {...}}}}
        err = body.get("error", {}) if isinstance(body, dict) else {}
        code = str(err.get("code", "")).lower()
        msg = str(err.get("message", "")).lower()
        haystack = f"{code} {msg} {body_text.lower()}"
    except Exception:  # noqa: BLE001
        try:
            body_text = (exc.response.text or "")[:2000]
        except Exception:  # noqa: BLE001
            body_text = ""
        haystack = body_text.lower()

    if any(k in haystack for k in _POLICY_KEYWORDS):
        return True, body_text
    return False, body_text


def generate_image_sync(
    prompt: str,
    out_path: str,
    *,
    style: str | None = None,
    reader_preference: str | None = None,
    size: str | None = None,
    quality: str = "medium",
    retries: int = 2,
    mood: str | None = None,
    composition: str | None = None,
    time_of_day: str | None = None,
    setting: str | None = None,
    palette_hint: str | None = None,
    base_palette: str | None = None,
    character_refs: list[str] | None = None,
) -> str:
    """Generate a single PNG via Azure gpt-image-2.

    `size` defaults to the aspect ratio that suits the composition —
    portrait for close-ups and low-angle shots, landscape for wides
    and establishing shots, square otherwise. Pass an explicit `size`
    to override.

    `quality` defaults to 'medium' — 'low' produces visibly muddy
    output for character close-ups. The Azure pricing delta between
    low and medium is small relative to the LLM cost per book.
    """
    if size is None:
        size = size_for_composition(composition)
    url = (
        f"{config.image_endpoint}/openai/deployments/{config.image_deployment}"
        f"/images/generations?api-version={config.image_api_version}"
    )
    body = {
        "prompt": compose_prompt(
            prompt,
            style=style,
            reader_preference=reader_preference,
            mood=mood,
            composition=composition,
            time_of_day=time_of_day,
            setting=setting,
            palette_hint=palette_hint,
            base_palette=base_palette,
            character_refs=character_refs,
        ),
        "size": size,
        "quality": quality,
        "output_compression": 100,
        "output_format": "png",
        "n": 1,
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {config.image_api_key}",
    }

    last_exc: Exception | None = None
    for attempt in range(retries + 1):
        try:
            r = requests.post(url, headers=headers, json=body, timeout=120)
            r.raise_for_status()
            b64 = r.json()["data"][0]["b64_json"]
            os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
            with open(out_path, "wb") as f:
                f.write(base64.b64decode(b64))
            return out_path
        except requests.HTTPError as exc:
            last_exc = exc
            status = exc.response.status_code if exc.response is not None else 0
            # Content-policy 400 → distinct exception so the softening
            # wrapper can catch it. Don't retry the same prompt.
            if status == 400:
                is_policy, body_text = _is_content_policy_400(exc)
                if is_policy:
                    raise ContentPolicyViolation(
                        f"Azure content policy rejected prompt: {body_text[:200]}",
                        body=body_text,
                    ) from exc
            if status < 500 or attempt == retries:
                raise
            time.sleep(1.5 * (attempt + 1))
        except requests.RequestException as exc:
            last_exc = exc
            if attempt == retries:
                raise
            time.sleep(1.5 * (attempt + 1))

    assert last_exc is not None
    raise last_exc


async def generate_image(
    prompt: str,
    out_path: str,
    *,
    style: str | None = None,
    reader_preference: str | None = None,
    mood: str | None = None,
    composition: str | None = None,
    time_of_day: str | None = None,
    setting: str | None = None,
    palette_hint: str | None = None,
    base_palette: str | None = None,
    character_refs: list[str] | None = None,
    quality: str = "medium",
    size: str | None = None,
) -> str:
    return await asyncio.to_thread(
        generate_image_sync,
        prompt,
        out_path,
        style=style,
        reader_preference=reader_preference,
        mood=mood,
        composition=composition,
        time_of_day=time_of_day,
        setting=setting,
        palette_hint=palette_hint,
        base_palette=base_palette,
        character_refs=character_refs,
        quality=quality,
        size=size,
    )


async def generate_image_with_softening(
    scene_text: str,
    out_path: str,
    *,
    style: str | None = None,
    reader_preference: str | None = None,
    max_softening_attempts: int = 2,
    retry_attempts: int = 6,
    label: str | None = None,
    mood: str | None = None,
    composition: str | None = None,
    time_of_day: str | None = None,
    setting: str | None = None,
    palette_hint: str | None = None,
    base_palette: str | None = None,
    character_refs: list[str] | None = None,
    quality: str = "medium",
) -> dict:
    """Generate an image, recovering from content-policy rejections by
    asking the softener LLM to rephrase the scene.

    Flow per attempt:
      1. Try the current scene text (with normal transient-retry budget).
      2. If Azure RAI rejects, log it, ask the softener to rewrite.
      3. Retry with the rewrite. Up to `max_softening_attempts` rewrites.

    Returns a dict:
      {
        "final_scene_text": str,        # what was actually sent on success
        "softened": bool,               # True iff at least one rewrite happened
        "softening_log": [
            {"attempt": int, "rejected_scene": str, "reason": str},
            ...
        ],
      }

    Raises ContentPolicyViolation if every softening attempt also fails
    (so the orchestrator can record the per-scene failure and move on
    instead of blocking the whole book on one stubborn moment).
    """
    current = scene_text
    log: list[dict] = []
    label = label or os.path.basename(out_path).rsplit(".", 1)[0]

    for attempt in range(max_softening_attempts + 1):
        try:
            await with_retries(
                lambda: generate_image(
                    current,
                    out_path,
                    style=style,
                    reader_preference=reader_preference,
                    mood=mood,
                    composition=composition,
                    time_of_day=time_of_day,
                    setting=setting,
                    palette_hint=palette_hint,
                    base_palette=base_palette,
                    character_refs=character_refs,
                    quality=quality,
                ),
                attempts=retry_attempts,
                label=f"image[{label}]",
            )
            return {
                "final_scene_text": current,
                "softened": attempt > 0,
                "softening_log": log,
            }
        except ContentPolicyViolation as exc:
            log.append({
                "attempt": attempt,
                "rejected_scene": current,
                "reason": str(exc)[:300],
            })
            if attempt == max_softening_attempts:
                raise
            # Lazy import: keeps the LLM-softener stack out of contexts
            # that just want the sync image generator (e.g. tests).
            from .image_softener import soften_scene
            print(f"[soften] image[{label}] policy rejection "
                  f"(attempt {attempt + 1}/{max_softening_attempts + 1}); "
                  f"asking softener to rephrase…")
            try:
                current = await soften_scene(
                    original=scene_text,
                    last_attempted=current,
                    rejection_reason=str(exc)[:500],
                    attempt_index=attempt,
                )
            except Exception as soften_exc:  # noqa: BLE001
                # If the softener itself fails (rare), give up cleanly.
                print(f"[soften] image[{label}] softener failed: "
                      f"{type(soften_exc).__name__}: {soften_exc}")
                raise exc from soften_exc
            preview = current.replace("\n", " ")[:120]
            print(f"[soften] image[{label}] new scene: {preview}…")

    raise RuntimeError("unreachable: softening loop exited without return/raise")
