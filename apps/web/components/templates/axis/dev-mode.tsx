"use client";

import { useEffect, useState, type SVGProps } from "react";
import { motion } from "motion/react";
import { Mic, Check, Square } from "lucide-react";

// --- Agent marks ------------------------------------------------------------
// Minimal, monochrome glyphs drawn in `currentColor` to match the site's
// lucide-style icon set — abstract representations of each CLI, NOT the vendors'
// trademarked logos. The actual dispatch targets mirror `DevAgentRegistry.all()`
// in the desktop app: Claude Code (the recommended default), Codex, and Cursor.

const ClaudeMark = ({ className, ...props }: SVGProps<SVGSVGElement>) => (
    <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.6}
        strokeLinecap="round"
        xmlns="http://www.w3.org/2000/svg"
        aria-hidden="true"
        className={className}
        {...props}
    >
        {/* 12-ray sunburst */}
        {Array.from({ length: 12 }).map((_, i) => {
            const a = (i * Math.PI) / 6;
            // Round to a fixed precision so the server- and client-rendered
            // attribute strings are byte-identical — raw float output can differ
            // and trips React's hydration mismatch warning.
            const x = (12 + Math.cos(a)).toFixed(4);
            const y = (12 + Math.sin(a)).toFixed(4);
            const x2 = (12 + Math.cos(a) * 8).toFixed(4);
            const y2 = (12 + Math.sin(a) * 8).toFixed(4);
            return <line key={i} x1={x} y1={y} x2={x2} y2={y2} />;
        })}
    </svg>
);

const CodexMark = ({ className, ...props }: SVGProps<SVGSVGElement>) => (
    <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.6}
        strokeLinecap="round"
        strokeLinejoin="round"
        xmlns="http://www.w3.org/2000/svg"
        aria-hidden="true"
        className={className}
        {...props}
    >
        {/* terminal prompt: >_ in a rounded frame */}
        <rect x="3" y="4" width="18" height="16" rx="3" />
        <path d="m8 10 2.5 2L8 14" />
        <path d="M13 15h3.5" />
    </svg>
);

const CursorMark = ({ className, ...props }: SVGProps<SVGSVGElement>) => (
    <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.6}
        strokeLinecap="round"
        strokeLinejoin="round"
        xmlns="http://www.w3.org/2000/svg"
        aria-hidden="true"
        className={className}
        {...props}
    >
        {/* angular pointer / cursor */}
        <path d="M5 3.5 18.5 11l-6 1.6-2.4 5.9z" />
    </svg>
);

type Agent = {
    name: string;
    icon: React.ComponentType<{ className?: string }>;
    note: string;
};

// Mirrors `DevAgentRegistry` — Claude Code is `recommendedID`, then Codex, Cursor.
const agents: Agent[] = [
    { name: "Claude Code", icon: ClaudeMark, note: "Recommended" },
    { name: "Codex", icon: CodexMark, note: "codex exec" },
    { name: "Cursor", icon: CursorMark, note: "cursor-agent" },
];

// --- DevMode flow animation -------------------------------------------------
// A small, looping "GIF-style" demo of the whole DevMode flow, built from
// markup + motion only (no image assets). It tells the three-step story the
// product is built around:
//   1. Select the area — the cursor drags a dashed box around the one card
//      on the page that doesn't match its siblings.
//   2. Say what you want — the user speaks the request out loud while the
//      mismatched card stays selected; Zerro captures it as a change spec.
//   3. Agent applies it — the agent rewrites that card so it matches the
//      rest, with the status pill moving from "Making changes" to "Done".
// The "describe" beat is split into listening → capturing so the cursor keeps
// moving while the request is spoken, but both belong to step 2. "apply" and
// "done" both belong to step 3 so the pill can show working → completed.

const PHASES = [
    { id: "select", step: 1, status: "Selecting area", ms: 2600 },
    { id: "describe", step: 2, status: "Listening", ms: 3000 },
    { id: "spec", step: 2, status: "Capturing your request", ms: 1800 },
    { id: "apply", step: 3, status: "Making changes", ms: 2600 },
    { id: "done", step: 3, status: "Done", ms: 2200 },
] as const;

// Names the three-step flow shown under the mock, mirroring the reference.
const STEPS = ["Select the area", "Say what you want", "Agent applies it"] as const;

// Solid-fill pointer (vs. the stroked CursorMark) so it reads on the dark mock.
function Cursor() {
    return (
        <svg
            viewBox="0 0 24 24"
            className="h-5 w-5 drop-shadow-[0_2px_4px_rgba(0,0,0,0.55)]"
            aria-hidden="true"
        >
            <path
                d="M5 3.5 18.5 11l-6 1.6-2.4 5.9z"
                fill="#ffffff"
                stroke="#0a0a0b"
                strokeWidth={1.4}
                strokeLinejoin="round"
            />
        </svg>
    );
}

function DevModeFlow() {
    const [phase, setPhase] = useState(0);

    // Advance through the phases on a per-phase timer, looping forever.
    useEffect(() => {
        const t = setTimeout(
            () => setPhase((p) => (p + 1) % PHASES.length),
            PHASES[phase].ms,
        );
        return () => clearTimeout(t);
    }, [phase]);

    const id = PHASES[phase].id;
    const step = PHASES[phase].step;
    const recording = id === "select" || id === "describe" || id === "spec";
    const selecting = id === "select";
    const speaking = id === "describe";
    const writingSpec = id === "spec";
    const working = id === "apply";
    const done = id === "done";
    // The mismatched card has been rewritten to match its siblings once the
    // agent starts working, and stays corrected through the "done" beat.
    const edited = working || done;
    // The dashed selection box stays around the target card from the moment the
    // cursor draws it until the change is applied.
    const selection = selecting || speaking || writingSpec;
    // The subtitle of what the user is saying appears while they describe the
    // change and lingers until Zerro has captured it.
    const showSubtitle = id === "describe" || id === "spec";
    // Status dot color follows the phase: live green while capturing, green
    // again as the change lands, neutral otherwise.
    const dotClass = recording || edited ? "bg-green-400" : "bg-white/40";
    // The dot pulses while recording and while the agent is actively editing.
    const pulseDot = recording || working;
    // The cursor is always on screen and moving through the flow: it drags the
    // selection over the off-card, drops to the caption bar while the request is
    // spoken, points at the captured spec, then rests on the card being fixed.
    const cursorPos =
        id === "select"
            ? { left: "62%", top: "46%" }
            : id === "describe"
              ? { left: "14%", top: "86%" }
              : id === "spec"
                ? { left: "60%", top: "30%" }
                : { left: "50%", top: "44%" };

    return (
        <div className="relative">
            {/* Ambient brand glow behind the mock */}
            <div
                aria-hidden="true"
                className="pointer-events-none absolute inset-0 z-0 flex items-center justify-center"
            >
                <div className="h-[110%] w-[120%] rounded-[50%] bg-green-500/20 opacity-70 blur-[120px]" />
            </div>

            {/* Browser-window mock — fixed gray chrome in both themes (matches the app) */}
            <div className="relative z-10 overflow-hidden rounded-2xl border border-white/10 bg-[#202022] p-3 shadow-[0_30px_80px_-30px_rgba(0,0,0,0.45)] sm:p-4">
                {/* Title bar */}
                <div className="mb-3 flex items-center gap-2 px-1">
                    <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                    <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                    <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                    <span className="ml-2 truncate rounded-md bg-white/[0.06] px-2 py-0.5 font-mono text-[11px] text-white/45">
                        localhost:3000
                    </span>
                    {/* Live status pill */}
                    <span className="ml-auto flex items-center gap-1.5 rounded-full bg-white/[0.06] px-2.5 py-1 text-[11px] font-medium text-white/70">
                        <motion.span
                            className={`h-1.5 w-1.5 rounded-full ${dotClass}`}
                            animate={
                                pulseDot
                                    ? { opacity: [1, 0.3, 1] }
                                    : { opacity: 1 }
                            }
                            transition={
                                pulseDot
                                    ? { duration: 1.1, repeat: Infinity }
                                    : { duration: 0.2 }
                            }
                        />
                        {PHASES[phase].status}
                    </span>
                </div>

                {/* Viewport — the page being recorded */}
                <div className="relative h-80 overflow-hidden rounded-xl bg-[#0a0a0b] ring-1 ring-white/[0.06] sm:h-[24rem] lg:h-[27rem]">
                    {/* Mock page content */}
                    <div className="flex h-full flex-col gap-4 p-5 sm:p-6">
                        {/* Header bar — fixed page chrome (not the edit target) */}
                        <div className="relative z-10 flex items-center justify-between rounded-lg bg-white/[0.04] px-3 py-2.5">
                            <div className="flex items-center gap-2">
                                <span className="h-3 w-3 rounded bg-green-400/70" />
                                <span className="h-2 w-14 rounded-full bg-white/30" />
                            </div>
                            <div className="flex items-center gap-1.5">
                                <span className="h-2 w-8 rounded-full bg-white/15" />
                                <span className="h-2 w-8 rounded-full bg-white/15" />
                                <span className="h-2 w-8 rounded-full bg-white/15" />
                            </div>
                        </div>

                        {/* Example website cards — three matching tiles, except
                            the middle one starts off-brand (amber, misaligned
                            widths). It's the div the user asks the agent to fix;
                            once `edited`, it animates back into the shared style. */}
                        <div className="grid grid-cols-3 gap-3">
                            {[0, 1, 2].map((i) => {
                                const target = i === 1;
                                // The middle card is mismatched until corrected.
                                const off = target && !edited;
                                return (
                                    <motion.div
                                        key={i}
                                        className="relative flex flex-col gap-2 rounded-lg p-3"
                                        animate={{
                                            backgroundColor: off
                                                ? "rgba(251,191,36,0.14)"
                                                : "rgba(255,255,255,0.04)",
                                        }}
                                        transition={{ duration: 0.45 }}
                                    >
                                        <motion.span
                                            className="h-6 w-6 rounded-md"
                                            animate={{
                                                backgroundColor: off
                                                    ? "rgba(251,191,36,0.6)"
                                                    : "rgba(255,255,255,0.15)",
                                            }}
                                            transition={{ duration: 0.45 }}
                                        />
                                        <motion.span
                                            className="block h-2 rounded-full"
                                            animate={{
                                                width: off ? "55%" : "100%",
                                                backgroundColor: off
                                                    ? "rgba(251,191,36,0.35)"
                                                    : "rgba(255,255,255,0.10)",
                                            }}
                                            transition={{ duration: 0.45 }}
                                        />
                                        <motion.span
                                            className="block h-2 rounded-full"
                                            animate={{
                                                width: off ? "85%" : "66%",
                                                backgroundColor: off
                                                    ? "rgba(251,191,36,0.35)"
                                                    : "rgba(255,255,255,0.10)",
                                            }}
                                            transition={{ duration: 0.45 }}
                                        />

                                        {/* Dashed selection box drawn around the
                                            mismatched card while it's selected */}
                                        {target && (
                                            <motion.span
                                                aria-hidden="true"
                                                className="pointer-events-none absolute -inset-1 rounded-lg border border-dashed border-green-400/80 bg-green-400/[0.06]"
                                                initial={false}
                                                animate={{ opacity: selection ? 1 : 0 }}
                                                transition={{ duration: 0.3 }}
                                            />
                                        )}

                                        {/* Check that pops once the card matches */}
                                        {target && (
                                            <motion.span
                                                className="absolute -right-1.5 -top-1.5 flex h-5 w-5 items-center justify-center rounded-full bg-green-400 text-neutral-900 shadow"
                                                initial={false}
                                                animate={{
                                                    opacity: edited ? 1 : 0,
                                                    scale: edited ? 1 : 0.6,
                                                }}
                                                transition={{ duration: 0.3 }}
                                            >
                                                <Check className="h-3 w-3" strokeWidth={3} />
                                            </motion.span>
                                        )}
                                    </motion.div>
                                );
                            })}
                        </div>

                        {/* Body skeleton */}
                        <div className="space-y-2.5">
                            <span className="block h-2 w-3/4 rounded-full bg-white/10" />
                            <span className="block h-2 w-1/2 rounded-full bg-white/10" />
                        </div>

                        {/* CTA — static page chrome */}
                        <div className="mt-auto w-fit">
                            <button
                                type="button"
                                className="rounded-lg bg-indigo-500 px-4 py-2 text-[13px] font-semibold text-white"
                            >
                                Get started
                            </button>
                        </div>
                    </div>

                    {/* REC / stop badge */}
                    <div className="absolute left-3 top-3">
                        {recording ? (
                            <span className="flex items-center gap-1.5 rounded bg-green-500/90 px-1.5 py-0.5 text-[10px] font-semibold text-white">
                                <motion.span
                                    className="h-1.5 w-1.5 rounded-full bg-white"
                                    animate={{ opacity: [1, 0.3, 1] }}
                                    transition={{ duration: 1.1, repeat: Infinity }}
                                />
                                REC
                            </span>
                        ) : (
                            <span className="flex items-center gap-1.5 rounded bg-white/10 px-1.5 py-0.5 text-[10px] font-semibold text-white/70">
                                <Square className="h-2 w-2 fill-current" strokeWidth={0} />
                                Stopped
                            </span>
                        )}
                    </div>

                    {/* Editing chip while the agent is actively making changes */}
                    <motion.div
                        className="absolute right-3 top-3 flex items-center gap-1 rounded bg-white/10 px-1.5 py-0.5 text-[10px] font-semibold text-white/80"
                        initial={false}
                        animate={{ opacity: working ? 1 : 0, y: working ? 0 : -4 }}
                        transition={{ duration: 0.3 }}
                    >
                        <motion.span
                            className="h-1.5 w-1.5 rounded-full bg-green-400"
                            animate={{ opacity: [1, 0.3, 1] }}
                            transition={{ duration: 0.9, repeat: Infinity }}
                        />
                        Editing
                    </motion.div>

                    {/* Done chip once the change has landed */}
                    <motion.div
                        className="absolute right-3 top-3 flex items-center gap-1 rounded bg-green-400/15 px-1.5 py-0.5 text-[10px] font-semibold text-green-400"
                        initial={false}
                        animate={{ opacity: done ? 1 : 0, y: done ? 0 : -4 }}
                        transition={{ duration: 0.3 }}
                    >
                        <Check className="h-3 w-3" strokeWidth={3} />
                        Done
                    </motion.div>

                    {/* Zerro writing the spec — a small card scans in */}
                    <motion.div
                        className="absolute right-3 top-12 w-44 rounded-lg border border-white/10 bg-[#161617] p-2.5 shadow-lg"
                        initial={false}
                        animate={{
                            opacity: writingSpec ? 1 : 0,
                            y: writingSpec ? 0 : 8,
                        }}
                        transition={{ duration: 0.3 }}
                    >
                        <div className="mb-1.5 flex items-center gap-1.5">
                            <span className="flex h-4 w-4 items-center justify-center rounded bg-white text-[10px] font-bold text-neutral-900">
                                Z
                            </span>
                            <span className="text-[11px] font-semibold text-white">
                                Change spec
                            </span>
                        </div>
                        <ul className="space-y-1 font-mono text-[10px] leading-snug text-white/60">
                            <li>1. Match this card to the others.</li>
                            <li>2. Use the shared card style.</li>
                        </ul>
                    </motion.div>

                    {/* Animated cursor — drags the selection over the off-card,
                        drops to the caption bar while the request is spoken,
                        points at the captured spec, then rests on the card as it
                        gets fixed. It's on screen through every step. */}
                    <motion.div
                        className="pointer-events-none absolute z-20"
                        initial={false}
                        animate={cursorPos}
                        transition={{ duration: 0.6, ease: "easeInOut" }}
                    >
                        <Cursor />
                    </motion.div>

                    {/* Subtitle — what the user is saying out loud */}
                    <motion.div
                        className="absolute inset-x-3 bottom-3 flex items-center gap-2 rounded-lg bg-black/70 px-3 py-2 backdrop-blur-sm"
                        initial={false}
                        animate={{
                            opacity: showSubtitle ? 1 : 0,
                            y: showSubtitle ? 0 : 8,
                        }}
                        transition={{ duration: 0.3 }}
                    >
                        <Mic className="h-3.5 w-3.5 shrink-0 text-green-400" strokeWidth={1.8} />
                        {/* Live waveform while speaking */}
                        <div className="flex shrink-0 items-end gap-[2px]">
                            {[0.5, 0.9, 0.6, 1, 0.55, 0.85].map((h, i) => (
                                <motion.span
                                    key={i}
                                    className="w-[2px] rounded-full bg-green-400/80"
                                    style={{ height: 14, originY: 1 }}
                                    animate={
                                        speaking
                                            ? { scaleY: [0.35, h, 0.35] }
                                            : { scaleY: 0.35 }
                                    }
                                    transition={
                                        speaking
                                            ? {
                                                  duration: 0.7,
                                                  repeat: Infinity,
                                                  delay: i * 0.07,
                                                  ease: "easeInOut",
                                              }
                                            : { duration: 0.2 }
                                    }
                                />
                            ))}
                        </div>
                        <span className="truncate text-[12px] text-white/85">
                            &ldquo;Fix this div so it matches the rest.&rdquo;
                        </span>
                    </motion.div>
                </div>
            </div>

            {/* Three-step flow — names the story the animation is acting out
                (select → say → apply), with the active step lit in sync with
                the current phase and finished steps marked done. */}
            <div className="relative z-10 mt-6 flex flex-wrap items-center justify-center gap-2 sm:gap-3">
                {STEPS.map((label, i) => {
                    const n = i + 1;
                    const active = step === n;
                    const complete = step > n;
                    return (
                        <div key={n} className="flex items-center gap-2 sm:gap-3">
                            <div
                                className={`flex items-center gap-2 rounded-full border px-3 py-1.5 transition-all duration-500 ${
                                    active
                                        ? "border-green-400/40 bg-green-400/10"
                                        : "border-border bg-transparent"
                                }`}
                            >
                                <span
                                    className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[11px] font-bold transition-colors duration-500 ${
                                        active
                                            ? "bg-green-400 text-neutral-900"
                                            : complete
                                              ? "bg-green-400/30 text-green-400"
                                              : "bg-muted-foreground/20 text-muted-foreground"
                                    }`}
                                >
                                    {complete ? (
                                        <Check className="h-3 w-3" strokeWidth={3} />
                                    ) : (
                                        n
                                    )}
                                </span>
                                <span
                                    className={`text-sm font-medium transition-colors duration-500 ${
                                        active ? "text-green-400" : "text-muted-foreground"
                                    }`}
                                >
                                    {label}
                                </span>
                            </div>
                            {n < STEPS.length && (
                                <span className="hidden h-px w-5 bg-border sm:block" />
                            )}
                        </div>
                    );
                })}
            </div>
        </div>
    );
}

const DevMode = () => {
    return (
        <motion.section
            id="dev-mode"
            className="relative mx-auto w-full scroll-mt-24"
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.15 }}
            transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
        >
            {/* Recording ring — the same pulsing green halo the app shows while
                DevMode is actively capturing. Spans edge-to-edge as a sharp
                full-width band; inner content stays constrained for readability. */}
            <motion.div
                className="relative rounded-none border border-green-500/30 px-4 py-12 sm:py-16"
                animate={{
                    // Inward pulse: an inset green glow that draws in from the
                    // edges toward the section. It never fully retracts — the
                    // floor sits roughly halfway so the glow always reads as
                    // "live", then breathes outward slowly to match the native
                    // macOS recording ring's calm cadence.
                    boxShadow: [
                        "0 0 0 1.2px rgba(34,197,94,0.42), inset 0 0 60px -8px rgba(34,197,94,0.42)",
                        "0 0 0 1.6px rgba(34,197,94,0.66), inset 0 0 92px -6px rgba(34,197,94,0.62)",
                        "0 0 0 1.2px rgba(34,197,94,0.42), inset 0 0 60px -8px rgba(34,197,94,0.42)",
                    ],
                }}
                transition={{ duration: 4.2, ease: "easeInOut", repeat: Infinity }}
            >
            <div className="mx-auto w-full max-w-7xl">
            {/* Centered section header — eyebrow + heading sit above the hero */}
            <div className="mx-auto mb-10 flex max-w-2xl flex-col items-center gap-3 text-center lg:mb-14">
                <p className="text-sm font-medium uppercase tracking-[0.18em] text-green-400">
                    DevMode
                </p>
                <h2 className="text-3xl font-medium leading-tight tracking-tight text-foreground sm:text-4xl lg:text-5xl">
                    Describe the changes,
                    <br />
                    watch them happen.
                </h2>
            </div>

            {/* Hero — animation on the left, copy on the right. The animation
                column takes the larger share so the mock reads bigger. */}
            <div className="grid items-center gap-10 lg:grid-cols-5 lg:gap-14">
                {/* Left column — the looping flow animation */}
                <div className="order-2 lg:order-1 lg:col-span-3">
                    <DevModeFlow />
                </div>

                {/* Right column — the pitch */}
                <div className="order-1 flex flex-col items-center gap-3 text-center lg:order-2 lg:col-span-2 lg:items-start lg:text-left">
                    <p className="max-w-xl text-lg font-medium tracking-tight text-green-400 sm:text-xl">
                        Build and iterate with just a single shortcut and your voice.
                    </p>
                    <p className="max-w-xl text-base text-muted-foreground">
                        Record your screen, say what you want changed, and Zerro turns it
                        into a clear, step-by-step plan — then hands it to your coding
                        agent, which makes the edits and updates your site as you watch.
                    </p>
                    <p className="max-w-xl text-lg font-semibold tracking-tight text-foreground">
                        No more capturing screenshots to explain what you mean — just
                        describe the change out loud and let your coding agent take it
                        from there.
                    </p>
                </div>
            </div>

            {/* Supported agents */}
            <div className="relative z-10 mx-auto mt-14 max-w-5xl lg:mt-20">
                <p className="mb-5 text-center text-sm font-medium uppercase tracking-[0.18em] text-muted-foreground">
                    Works with your CLI agent
                </p>
                <div className="grid grid-cols-1 gap-px overflow-hidden rounded-2xl border border-border bg-border sm:grid-cols-3">
                    {agents.map((agent) => {
                        const Icon = agent.icon;
                        return (
                            <div
                                key={agent.name}
                                className="flex items-center gap-3 bg-background px-5 py-4"
                            >
                                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-green-400/10 text-green-400">
                                    <Icon className="h-5 w-5" />
                                </div>
                                <div className="flex flex-col">
                                    <span className="text-base font-medium tracking-tight text-foreground">
                                        {agent.name}
                                    </span>
                                    <span className="text-xs text-muted-foreground">
                                        {agent.note}
                                    </span>
                                </div>
                            </div>
                        );
                    })}
                </div>
                <p className="mt-6 text-center text-sm text-muted-foreground">
                    Bring your own agent — Zerro auto-detects the CLIs installed on
                    your Mac and runs the one you pick, locally.
                </p>
            </div>
            </div>
            </motion.div>
        </motion.section>
    );
};

export default DevMode;
