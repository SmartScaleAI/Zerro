"use client";

import { useState } from "react";
import { motion } from "motion/react";
import {
    Check,
    Braces,
    Mail,
    Code,
    FileText,
    ChevronUp,
    X,
    type LucideIcon,
} from "lucide-react";

// A recording produces one of several typed artifacts. Each type has its own
// card title, one-line description, body rendering, header icon, and copy-button
// label — mirroring `enum ArtifactType` in
// apps/desktop/Zerro/Services/ResponseModels.swift (the source of truth).
type ArtifactType = "agent_prompt" | "message" | "snippet" | "document";

// How the body panel renders for a given type.
type BodyRender = "agent" | "message" | "snippet" | "document";

type ArtifactSpec = {
    /** Label on the segmented toggle above the card. */
    toggleLabel: string;
    /** Card header title (bold white). Per-type, replaces the old "Prompt ready". */
    title: string;
    /** One-line description under the header. */
    description: string;
    /** Copy-button label (verbatim from the §2 contract). */
    buttonLabel: string;
    /** Header / button icon (lucide equivalent of the contract glyph). */
    icon: LucideIcon;
    /** How the body panel is laid out and fonted. */
    render: BodyRender;
    /** Whether the body uses a monospace font. */
    mono: boolean;
    /** The artifact body — the Copy button copies this verbatim, nothing else. */
    body: string;
};

// Exact example bodies — kept as raw strings so Copy grabs the body exactly.
const AGENT_PROMPT_BODY = `Fix the promo-code validation on the checkout Order Summary.
1. Locate the "Apply" button beside the promo-code field (current value: SAVE20) in the Order Summary panel.
2. When an applied code is invalid or expired, the field currently does nothing — no error, no spinner, no state change.
3. On an invalid code, render an inline error directly beneath the field in red (e.g. "This code is expired or invalid").
4. Keep the existing layout and totals; this is a validation fix, not a redesign.`;

const MESSAGE_BODY = `Subject: Launch moving to Friday
Hi Sarah,
Quick heads-up on the launch timeline. The API migration ran longer than we scoped, so we're moving the launch from Tuesday to Friday to land the cutover cleanly rather than rush it.
The Thursday demo is unaffected — everything we're showing there is already in place.
Sorry for the shift. I'll send a firm Friday window by end of day tomorrow.
Thanks,
[You]`;

const SNIPPET_BODY = `=SUMIF(B:B, "Paid", C:C)`;

const DOCUMENT_BODY = `Roadmap Offsite — Summary
Decided
- Q3 priorities are locked and dated.
- Checkout revamp ships first, ahead of the billing work.
Open
- Platform rewrite — still under discussion; not committed for Q3.
- Mobile parity — scope TBD pending the rewrite call.
Owners
- Checkout revamp — Priya
- Billing — Marcus
- Platform rewrite decision — Sarah, by end of month`;

const ARTIFACT_ORDER: ArtifactType[] = [
    "agent_prompt",
    "message",
    "snippet",
    "document",
];

const ARTIFACTS: Record<ArtifactType, ArtifactSpec> = {
    agent_prompt: {
        toggleLabel: "Prompt",
        title: "Show an inline error when an invalid promo code is applied",
        description:
            "Instructs your AI agent to fix the silent failure on the checkout promo-code field and surface a clear validation error.",
        buttonLabel: "Copy Prompt",
        icon: Braces,
        render: "agent",
        mono: true,
        body: AGENT_PROMPT_BODY,
    },
    message: {
        toggleLabel: "Message",
        title: "Email Sarah: launch slipping Tuesday → Friday",
        description:
            "A ready-to-send note about the timeline change — apologetic, but not groveling.",
        buttonLabel: "Copy draft",
        icon: Mail,
        render: "message",
        mono: false,
        body: MESSAGE_BODY,
    },
    snippet: {
        toggleLabel: "Snippet",
        title: 'SUMIF — total of column C where column B is "Paid"',
        description:
            "The exact formula to paste into your cell — totals column C for every row marked Paid in column B.",
        buttonLabel: "Copy snippet",
        icon: Code,
        render: "snippet",
        mono: true,
        body: SNIPPET_BODY,
    },
    document: {
        toggleLabel: "Document",
        title: "Roadmap offsite — team summary",
        description:
            "Your raw offsite notes written up as a shareable summary, organized into what's decided, what's open, and who owns what.",
        buttonLabel: "Copy text",
        icon: FileText,
        render: "document",
        mono: false,
        body: DOCUMENT_BODY,
    },
};

// --- Per-type body renderers ------------------------------------------------

// Agent prompt: markdown, mono-leaning — an intro line followed by numbered steps.
function AgentBody({ body }: { body: string }) {
    const lines = body.split("\n");
    const intro = lines[0];
    const steps = lines.slice(1);
    return (
        <>
            <p className="text-white/80">{intro}</p>
            <ol className="space-y-2 text-white/65">
                {steps.map((step, i) => (
                    <li key={i}>{step}</li>
                ))}
            </ol>
        </>
    );
}

// Message: prose — each line is its own paragraph.
function MessageBody({ body }: { body: string }) {
    const lines = body.split("\n");
    return (
        <>
            {lines.map((line, i) => (
                <p key={i} className={i === 0 ? "text-white/55" : "text-white/80"}>
                    {line}
                </p>
            ))}
        </>
    );
}

// Snippet: monospace, exact — rendered verbatim with preserved whitespace.
function SnippetBody({ body }: { body: string }) {
    return (
        <pre className="overflow-x-auto whitespace-pre-wrap text-white/90">
            {body}
        </pre>
    );
}

// Document: prose — a title, bold section headings, and bullet lists.
function DocumentBody({ body }: { body: string }) {
    const lines = body.split("\n");
    return (
        <div className="space-y-3">
            {lines.map((line, i) => {
                if (i === 0) {
                    return (
                        <p key={i} className="text-base font-semibold text-white">
                            {line}
                        </p>
                    );
                }
                if (line.startsWith("- ")) {
                    return (
                        <p key={i} className="pl-4 text-white/70">
                            • {line.slice(2)}
                        </p>
                    );
                }
                return (
                    <p key={i} className="pt-1 font-semibold text-white/85">
                        {line}
                    </p>
                );
            })}
        </div>
    );
}

// Copy text to the clipboard, returning whether it succeeded. Prefers the
// async Clipboard API and falls back to a hidden-textarea `execCommand` copy so
// the button still works in non-secure contexts (e.g. plain-http previews).
async function copyText(text: string): Promise<boolean> {
    try {
        if (navigator.clipboard?.writeText) {
            await navigator.clipboard.writeText(text);
            return true;
        }
    } catch {
        // Fall through to the legacy path below.
    }
    try {
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.setAttribute("readonly", "");
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        textarea.style.pointerEvents = "none";
        document.body.appendChild(textarea);
        textarea.select();
        const ok = document.execCommand("copy");
        document.body.removeChild(textarea);
        return ok;
    } catch {
        return false;
    }
}

function ArtifactBody({ spec }: { spec: ArtifactSpec }) {
    switch (spec.render) {
        case "agent":
            return <AgentBody body={spec.body} />;
        case "message":
            return <MessageBody body={spec.body} />;
        case "snippet":
            return <SnippetBody body={spec.body} />;
        case "document":
            return <DocumentBody body={spec.body} />;
    }
}

export default function ToolFeature() {
    const [type, setType] = useState<ArtifactType>("agent_prompt");
    const [copied, setCopied] = useState(false);

    const spec = ARTIFACTS[type];
    const Icon = spec.icon;

    const handleCopy = async () => {
        // Per the §2 contract, the copy payload is the body only, verbatim.
        const ok = await copyText(spec.body);
        if (ok) {
            setCopied(true);
            setTimeout(() => setCopied(false), 1500);
        }
    };

    return (
        <motion.section
            id="output"
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.15 }}
            transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
            className="relative mx-auto w-full max-w-7xl px-4 scroll-mt-24"
        >
            <div className="mb-12 lg:mb-16 flex flex-col items-center gap-3 text-center">
                <p className="text-sm font-medium uppercase tracking-[0.18em] text-primary">
                    The output
                </p>
                <h2 className="text-3xl font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl max-w-2xl leading-tight">
                    Never type again.
                </h2>
                <p className="max-w-xl text-base text-muted-foreground">
                    Every recording becomes exactly what you need — an agent prompt, a message, a snippet, or a document, written up and ready to use. Or, when you just want to understand something, a clear answer in plain language.
                </p>
            </div>

            <div className="relative mx-auto max-w-4xl">
                {/* Ambient glow behind the card */}
                <div
                    aria-hidden="true"
                    className="absolute inset-0 z-0 flex items-center justify-center pointer-events-none"
                >
                    <div
                        className="h-[130%] w-[150%] rounded-[50%] opacity-65 blur-[140px]"
                        style={{
                            background:
                                "radial-gradient(ellipse at center, rgba(255,255,255,0.58), rgba(255,255,255,0) 72%)",
                        }}
                    />
                </div>

                {/* Example switcher — frames the card as a marketing illustration of the
                    artifact types (one recording), NOT a live control on a user's result. */}
                <div className="relative z-10 mb-5 flex flex-wrap items-center justify-between gap-3">
                    <p className="text-sm font-medium uppercase tracking-[0.18em] text-muted-foreground">
                        One recording. The right artifact.
                    </p>
                    <div
                        role="group"
                        aria-label="Show example artifact type"
                        className="flex flex-wrap items-center gap-0.5 rounded-2xl bg-foreground/[0.06] p-0.5 ring-1 ring-foreground/10 sm:rounded-full"
                    >
                        {ARTIFACT_ORDER.map((t) => (
                            <button
                                key={t}
                                type="button"
                                onClick={() => setType(t)}
                                aria-pressed={type === t}
                                className={`rounded-full px-3 py-1 text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-foreground/40 ${
                                    type === t
                                        ? "bg-foreground text-background"
                                        : "text-muted-foreground hover:text-foreground"
                                }`}
                            >
                                {ARTIFACTS[t].toggleLabel}
                            </button>
                        ))}
                    </div>
                </div>

                {/* Artifact card — fixed gray chrome in both themes (matches the app) */}
                <div className="relative z-10 overflow-hidden rounded-2xl border border-white/10 bg-[#202022] shadow-[0_30px_80px_-30px_rgba(0,0,0,0.4)]">
                    {/* Header row — check + title (left), decorative shell controls (right) */}
                    <div className="flex items-start justify-between gap-3 px-5 py-3.5">
                        <div className="flex min-w-0 items-center gap-2.5">
                            <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-green-500">
                                <Check className="h-3 w-3 text-white" strokeWidth={3} />
                            </span>
                            <span className="text-[15px] font-semibold leading-snug text-white">
                                {spec.title}
                            </span>
                        </div>
                        {/* Decorative shell controls — match the app, non-functional. */}
                        <div
                            aria-hidden="true"
                            className="flex shrink-0 items-center gap-3 pt-0.5"
                        >
                            <span className="flex items-center gap-1 text-sm text-white/50">
                                Hide
                                <ChevronUp className="h-4 w-4" />
                            </span>
                            <span className="text-white/40">
                                <X className="h-4 w-4" />
                            </span>
                        </div>
                    </div>

                    {/* Description line — one sentence, muted, above the body. */}
                    <div className="px-5 pb-3">
                        <p className="text-sm leading-relaxed text-white/60">
                            {spec.description}
                        </p>
                    </div>

                    {/* Body — inset near-black panel framed by the gray chrome */}
                    <div className="px-3">
                        <div
                            className={`space-y-5 rounded-xl bg-[#0a0a0b] px-6 py-7 text-sm leading-relaxed text-white/80 ring-1 ring-white/[0.06] lg:px-8 ${
                                spec.mono ? "font-mono" : ""
                            }`}
                        >
                            <ArtifactBody spec={spec} />
                        </div>
                    </div>

                    {/* Footer row — copy pill with type icon + label (right) */}
                    <div className="flex flex-wrap items-center justify-end gap-3 px-5 py-3.5">
                        <button
                            type="button"
                            onClick={handleCopy}
                            className={`flex items-center gap-2 rounded-full px-4 py-1.5 text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 ${
                                copied
                                    ? "bg-[#30D158] text-white focus-visible:ring-[#30D158]/60"
                                    : "bg-white text-neutral-900 hover:bg-white/90 focus-visible:ring-white/60"
                            }`}
                        >
                            {copied ? (
                                <>
                                    <Check className="h-3.5 w-3.5" />
                                    Copied
                                </>
                            ) : (
                                <>
                                    <Icon className="h-3.5 w-3.5" />
                                    {spec.buttonLabel}
                                </>
                            )}
                        </button>
                    </div>
                </div>

                <p className="mt-6 text-center text-sm text-muted-foreground">
                    Example output. Every prompt is generated from your real recording.
                </p>
            </div>
        </motion.section>
    );
}
