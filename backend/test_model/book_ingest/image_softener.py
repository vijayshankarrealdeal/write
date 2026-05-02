"""LLM-based prompt softener for image-gen content-policy rejections.

When Azure's image API rejects a prompt as a content-policy violation
(typical for classic literature with creation/violence/body-horror
scenes — Frankenstein, Dracula, etc.), the softener rewrites the scene
description to be visually striking but compliant.

Strategy: replace explicit imagery with implication. A creation scene
becomes lab-light + storm + silhouette. A monster confrontation becomes
shadow-on-shadow + alpine atmosphere. The narrative moment is
preserved; the explicit content is removed.

We use the cheap cleaner model — softening is a simple text-rewrite
task and doesn't need a frontier model. Budget impact: roughly $0.001
per softened scene.
"""

from __future__ import annotations

from pydantic import BaseModel, Field
from pydantic_ai import Agent

from .agents import cleaner_model
from .retry import with_retries


class SoftenedScene(BaseModel):
    """The softener's output."""
    scene_text: str = Field(
        ...,
        description=(
            "The rewritten scene description: 1–3 sentences, fully "
            "visual, depicting the same narrative moment but with "
            "imagery the content policy will accept. No preface, "
            "no explanation."
        ),
    )


_SYSTEM_PROMPT = (
    "You are an art director rewriting a scene description for a book "
    "illustration. Azure's image API rejected the original description "
    "as a content-policy violation. Your job is to rewrite it as a "
    "compelling, visually evocative scene that depicts the SAME "
    "narrative moment with the same emotional weight, but using ONLY "
    "imagery the policy will accept.\n\n"
    "Rules — strict:\n"
    "  • REPLACE explicit violence, gore, blood, dismemberment, body "
    "horror, sexual content, nudity, graphic injury, suicide, or "
    "torture with IMPLICATION: shadow, silhouette, aftermath, "
    "environmental cues, light/dark contrast, weather, posture, "
    "symbolic objects.\n"
    "  • A creation/reanimation scene: emphasise lab apparatus, "
    "candlelight, storm light, glassware, electric arcs, the "
    "scientist's silhouette — NOT the body or anatomical details.\n"
    "  • A confrontation scene: emphasise distance, scale contrast, "
    "fog/mist, two silhouettes, alpine landscape — NOT physical "
    "violence.\n"
    "  • A grief/death scene: empty room, cold light through windows, "
    "an overturned chair, distant figure, gravestone in mist — NOT "
    "the deceased.\n"
    "  • Keep the time of day, weather, location, and emotional tone "
    "of the original. The illustration should feel like the same "
    "moment in the story — just told through atmosphere instead of "
    "explicit depiction.\n"
    "  • Stay concrete and visual. Describe what a painter would put "
    "on the canvas. Don't generalise (\"a dramatic moment\").\n"
    "  • 1–3 sentences, max ~180 words.\n"
    "  • Output ONLY the rewritten scene_text — no preface, no quotes, "
    "no \"Here is the rewritten scene:\".\n\n"
    "The book is a classic work of literature being illustrated for "
    "general adult readers. The illustration should be tasteful and "
    "evocative, NOT explicit."
)


softener_agent: Agent[None, SoftenedScene] = Agent(
    model=cleaner_model,
    output_type=SoftenedScene,
    system_prompt=_SYSTEM_PROMPT,
)


async def soften_scene(
    *,
    original: str,
    last_attempted: str,
    rejection_reason: str | None = None,
    attempt_index: int = 0,
) -> str:
    """Ask the softener to rewrite `last_attempted`.

    `original` and `last_attempted` differ when this is the *second*
    softening pass — we already rewrote once, that rewrite also got
    rejected, and we're trying again with a stronger nudge toward
    abstraction. Showing both lets the LLM see what didn't fly.

    Wrapped in `with_retries` so a flaky cleaner endpoint doesn't kill
    the whole image-gen pipeline.
    """
    user_msg_parts: list[str] = [f"Original scene: {original.strip()}"]
    if last_attempted.strip() != original.strip():
        user_msg_parts.append(
            f"Previous rewrite (also rejected): {last_attempted.strip()}"
        )
    if rejection_reason:
        user_msg_parts.append(
            f"Azure rejection details (truncated): {rejection_reason[:300]}"
        )
    if attempt_index >= 1:
        user_msg_parts.append(
            "This is the second softening pass — be more abstract. "
            "Lean further on mood, weather, light, silhouette, and "
            "metaphor. If the previous rewrite still depicted a body, "
            "remove the body entirely and show only the aftermath or "
            "the environment around it."
        )
    user_msg_parts.append(
        "Rewrite the scene per the rules. Output only scene_text."
    )

    user_msg = "\n\n".join(user_msg_parts)
    run = await with_retries(
        lambda: softener_agent.run(user_msg),
        attempts=4,
        label="softener",
    )
    return run.output.scene_text.strip()
