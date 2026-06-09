"use client";

import { useState } from "react";
import { motion } from "motion/react";
import { Copy, Check, FileText, ChevronUp } from "lucide-react";

type OutputMode = "instruct" | "explain";

// Exact example outputs — kept as raw strings so the Copy button copies verbatim.
const INSTRUCT_EXAMPLE = `Improve the sign-in screen's conversion by fixing layout, hierarchy, and accessibility issues on the login form.

- Move the "Forgot password?" link up into the Sign In cluster, directly below the password field.
- Tighten the helper copy so it fits on a single line rather than wrapping.
- Change the primary call-to-action from muted gray to the brand blue.
- Fix the tab order so the "Remember me" checkbox is reachable by keyboard.

Keep the existing form fields and overall layout; these are refinements, not a redesign.`;

const EXPLAIN_EXAMPLE = `This is the sign-in screen for a SaaS dashboard, where users arriving from marketing log in to their account.

The form collects an email and password, with a "Remember me" checkbox and a primary "Sign In" button. A "Forgot password?" link sits below the form, separated from the fields by a block of helper text. Notably, a few details work against the screen's goal of converting visitors: the primary button uses a muted gray instead of the brand's blue, the helper copy wraps to three lines on mobile, and the keyboard tab order skips the "Remember me" checkbox, making it unreachable without a mouse.`;

const EXAMPLES: Record<OutputMode, string> = {
    instruct: INSTRUCT_EXAMPLE,
    explain: EXPLAIN_EXAMPLE,
};

const FORMAT_LABELS: Record<OutputMode, string> = {
    instruct: "Instruct · Markdown",
    explain: "Explain · Plain text",
};

export default function ToolFeature() {
    const [mode, setMode] = useState<OutputMode>("instruct");
    const [copied, setCopied] = useState(false);

    const example = EXAMPLES[mode];

    const handleCopy = async () => {
        try {
            await navigator.clipboard.writeText(example);
            setCopied(true);
            setTimeout(() => setCopied(false), 1500);
        } catch {
            // Clipboard unavailable (e.g. insecure context) — fail silently.
        }
    };

    // Instruct renders as markdown (intro line, bullet list, closing line);
    // Explain renders as plain paragraphs.
    const isInstruct = mode === "instruct";
    const lines = example.split("\n");
    const intro = lines[0];
    const bullets = lines.filter((l) => l.startsWith("- ")).map((l) => l.slice(2));
    const closing = lines[lines.length - 1];
    const paragraphs = example.split("\n\n");

    return (
        <motion.section
            id="output"
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.15 }}
            transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
            className="relative mx-auto w-full max-w-7xl px-4"
        >
            <div className="mb-12 lg:mb-16 flex flex-col items-center gap-3 text-center">
                <p className="text-sm font-medium uppercase tracking-[0.18em] text-primary">
                    The output
                </p>
                <h2 className="text-3xl font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl max-w-2xl leading-tight">
                    The prompt writes itself.
                </h2>
                <p className="max-w-xl text-base text-muted-foreground">
                    Every recording becomes exactly what you need: a structured instruction your agent can act on, or a clear explanation in plain language.
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
                    two modes (same recording), NOT a live control on a user's result. */}
                <div className="relative z-10 mb-5 flex flex-wrap items-center justify-between gap-3">
                    <p className="text-sm font-medium uppercase tracking-[0.18em] text-muted-foreground">
                        Same recording, two modes
                    </p>
                    <div
                        role="group"
                        aria-label="Show example output mode"
                        className="flex items-center rounded-full bg-foreground/[0.06] p-0.5 ring-1 ring-foreground/10"
                    >
                        {(["instruct", "explain"] as const).map((m) => (
                            <button
                                key={m}
                                type="button"
                                onClick={() => setMode(m)}
                                aria-pressed={mode === m}
                                className={`rounded-full px-3.5 py-1 text-sm font-medium capitalize transition-colors ${
                                    mode === m
                                        ? "bg-foreground text-background"
                                        : "text-muted-foreground hover:text-foreground"
                                }`}
                            >
                                {m}
                            </button>
                        ))}
                    </div>
                </div>

                {/* Prompt card — fixed gray chrome in both themes (matches the app) */}
                <div className="relative z-10 overflow-hidden rounded-2xl border border-white/10 bg-[#202022] shadow-[0_30px_80px_-30px_rgba(0,0,0,0.4)]">
                    {/* Top bar — status + actions */}
                    <div className="flex flex-wrap items-center justify-between gap-3 px-5 py-3.5">
                        <div className="flex items-center gap-2.5">
                            <span className="flex h-5 w-5 items-center justify-center rounded-full bg-green-500">
                                <Check className="h-3 w-3 text-white" strokeWidth={3} />
                            </span>
                            <span className="text-[15px] font-semibold text-white">
                                Prompt ready
                            </span>
                        </div>
                        <div className="flex items-center gap-3 sm:gap-4">
                            <button
                                type="button"
                                onClick={handleCopy}
                                className="flex items-center gap-2 rounded-full bg-white px-4 py-1.5 text-sm font-medium text-neutral-900 transition-colors hover:bg-white/90"
                            >
                                {copied ? (
                                    <>
                                        <Check className="h-3.5 w-3.5" />
                                        Copied
                                    </>
                                ) : (
                                    <>
                                        <Copy className="h-3.5 w-3.5" />
                                        Copy
                                    </>
                                )}
                            </button>
                            <button className="flex items-center gap-1 text-sm text-white/50 transition-colors hover:text-white/80">
                                Hide
                                <ChevronUp className="h-4 w-4" />
                            </button>
                        </div>
                    </div>

                    {/* Sub-header — file label (reflects active mode) */}
                    <div className="flex items-center gap-2 border-t border-white/[0.07] px-5 py-3">
                        <FileText className="h-3.5 w-3.5 text-white/40" />
                        <span className="font-mono text-sm uppercase tracking-wider text-white/40">
                            {FORMAT_LABELS[mode]}
                        </span>
                    </div>

                    {/* Body — inset near-black panel framed by the gray chrome */}
                    <div className="px-3 pb-3">
                        <div className="space-y-5 rounded-xl bg-[#0a0a0b] px-6 py-7 font-mono text-sm leading-relaxed text-white/80 ring-1 ring-white/[0.06] lg:px-8">
                            {isInstruct ? (
                                <>
                                    <p className="text-white/80">{intro}</p>
                                    <ul className="space-y-1 text-white/65">
                                        {bullets.map((bullet, i) => (
                                            <li key={i}>- {bullet}</li>
                                        ))}
                                    </ul>
                                    <p className="text-white/65">{closing}</p>
                                </>
                            ) : (
                                paragraphs.map((para, i) => (
                                    <p key={i} className="text-white/80">
                                        {para}
                                    </p>
                                ))
                            )}
                        </div>
                    </div>
                </div>

                <p className="mt-6 text-center text-sm text-muted-foreground">
                    Example output. Every prompt is generated from your real recording.
                </p>
            </div>
        </motion.section>
    );
}
