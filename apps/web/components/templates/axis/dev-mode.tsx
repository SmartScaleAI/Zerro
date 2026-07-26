"use client";

import { useEffect, useState, type SVGProps } from "react";
import { motion, AnimatePresence } from "motion/react";
import { Mic, Check, X } from "lucide-react";

// --- Agent marks ------------------------------------------------------------
// Monochrome glyphs drawn in `currentColor` to match the site's lucide-style
// icon set. Claude Code stays an abstract sunburst; Codex and Cursor use their
// vendors' brand marks (OpenAI and Cursor) recolored to the section's accent.
// The dispatch targets mirror `DevAgentRegistry.all()` in the desktop app:
// Claude Code (the recommended default), Codex, and Cursor.

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
        fill="currentColor"
        xmlns="http://www.w3.org/2000/svg"
        aria-hidden="true"
        className={className}
        {...props}
    >
        {/* OpenAI mark — Codex runs on OpenAI / ChatGPT */}
        <path d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.6813zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z" />
    </svg>
);

const CursorMark = ({ className, ...props }: SVGProps<SVGSVGElement>) => (
    <svg
        viewBox="0 0 24 24"
        fill="currentColor"
        xmlns="http://www.w3.org/2000/svg"
        aria-hidden="true"
        className={className}
        {...props}
    >
        {/* Cursor mark — an isometric cube; the three visible faces carry
            descending opacity to echo the logo's light-to-dark facets while
            staying in `currentColor` (the section's green accent). */}
        <path d="M12 2 21 7 12 12 3 7Z" opacity={0.95} />
        <path d="M21 7 21 17 12 22 12 12Z" opacity={0.7} />
        <path d="M3 7 12 12 12 22 3 17Z" opacity={0.5} />
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
    // The cursor leaves the card and moves up to the Stop button in the pill;
    // when it lands (this phase ends) the recording stops and step 3 begins.
    { id: "reach", step: 2, status: "Capturing your request", ms: 850 },
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
    // Live recording timer (seconds), shown in the pill during step 2.
    const [seconds, setSeconds] = useState(0);

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

    // While recording (step 2), tick the timer up one second at a time; reset it
    // whenever recording isn't active so each loop starts fresh at 0:00.
    const recording = step === 2;
    useEffect(() => {
        if (!recording) {
            setSeconds(0);
            return;
        }
        const t = setInterval(() => setSeconds((s) => s + 1), 1000);
        return () => clearInterval(t);
    }, [recording]);

    const selecting = id === "select";
    const speaking = id === "describe";
    const writingSpec = id === "spec";
    const working = id === "apply";
    const done = id === "done";
    // The mismatched card has been rewritten to match its siblings once the
    // agent starts working, and stays corrected through the "done" beat.
    const edited = working || done;
    // Step 1 draws the selection: the cursor drags a marquee across all three
    // cards (the box grows from its top-left corner in sync), and the green
    // dashed region then stays put over all three cards through every step.
    // The subtitle of what the user is saying appears while they describe the
    // change and lingers until Zerro has captured it.
    const showSubtitle = id === "describe" || id === "spec";
    // The cursor lives at the mock level (so it can travel between the cards and
    // the pill up in the title bar). `top` is in px because the vertical layout
    // is a fixed pixel stack from the mock's top (the extra viewport height at
    // larger breakpoints is added below the cards), so px stays put across
    // breakpoints; `left` is a width-relative %. The flow: drag the marquee
    // corner → circle the middle card while talking → move up to the Stop button
    // in the pill (landing there ends step 2) → drag back down onto the card.
    // The Stop button lives in the centered, fixed-width status pill, so its
    // position is a constant pixel offset from the mock's horizontal center —
    // NOT a fixed % of the mock's width. The reach phase therefore parks the
    // cursor at the center (left 50%) and pushes it right by a fixed `x` offset
    // so the tip lands on Stop at every breakpoint (a width-relative % like
    // "64%" only lined up on the wide desktop mock and fell short on mobile).
    const cursorPos =
        id === "select"
            ? { left: ["3%", "95%"], top: ["104px", "246px"], x: 0 }
            : id === "describe" || id === "spec"
              ? { left: "50%", top: "176px", x: 0 }
              : id === "reach"
                ? { left: "50%", top: "20px", x: 92 }
                : { left: "50%", top: "176px", x: 0 }; // apply, done — dragged back down
    // The select drag is a slow sweep; the trip up to Stop and the drag back down
    // are deliberate moves; every other reposition is a quick glide.
    const cursorTransition =
        selecting
            ? { duration: 1.4, ease: "easeInOut" as const }
            : id === "reach" || id === "apply"
              ? { duration: 0.8, ease: "easeInOut" as const }
              : { duration: 0.6, ease: "easeInOut" as const };

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
                <div className="relative mb-3 flex items-center gap-2 px-1">
                    <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                    <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                    <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                    <span className="ml-2 hidden truncate rounded-md bg-white/[0.06] px-2 py-0.5 font-mono text-[11px] text-white/45 sm:block">
                        localhost:3000
                    </span>

                    {/* Centered status pill — a small replica of the app's
                        control pill. One fixed-size shell is on screen the whole
                        time; its three content layers (select prompt → live
                        recording → changes applied) are stacked in a single grid
                        cell and cross-fade by step, so every pill is the same
                        width and height and they dissolve into each other. */}
                    <div className="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2">
                        <AnimatePresence>
                            {(step === 1 || step === 2 || step === 3) && (
                                <motion.div
                                    key="status-pill"
                                    initial={{ opacity: 0, y: -4, scale: 0.96 }}
                                    animate={{ opacity: 1, y: 0, scale: 1 }}
                                    exit={{ opacity: 0, y: -4, scale: 0.96 }}
                                    transition={{ duration: 0.3, ease: "easeInOut" }}
                                    className="relative grid h-7 w-[248px] overflow-hidden rounded-full border border-white/10 bg-black/75 px-1 shadow-lg backdrop-blur-sm sm:w-[255px]"
                                >
                                            {/* step 1 — drag-to-select prompt */}
                                            <motion.div
                                                initial={false}
                                                animate={{ opacity: step === 1 ? 1 : 0 }}
                                                transition={{ duration: 0.2 }}
                                                className="flex w-full items-center justify-between pr-2 [grid-area:1/1]"
                                            >
                                                {/* left — prompt */}
                                                <div className="flex items-center gap-1.5">
                                                    {/* hollow ready ring */}
                                                    <span className="h-2 w-2 shrink-0 rounded-full border border-white/40" />
                                                    <span className="shrink-0 whitespace-nowrap text-[10px] text-white/90">
                                                        Drag to select an area to narrate
                                                    </span>
                                                </div>
                                                {/* right — cancel */}
                                                <span className="shrink-0 text-[10px] text-white/40">
                                                    Cancel
                                                </span>
                                            </motion.div>
                                            {/* step 2 — live recording */}
                                            <motion.div
                                                initial={false}
                                                animate={{ opacity: step === 2 ? 1 : 0 }}
                                                transition={{ duration: 0.2 }}
                                                className="flex w-full items-center justify-between [grid-area:1/1]"
                                            >
                                                {/* left — recording info */}
                                                <div className="flex items-center gap-1.5">
                                                    {/* pulsing red record dot */}
                                                    <motion.span
                                                        className="h-2 w-2 shrink-0 rounded-full bg-red-500"
                                                        animate={{ opacity: [1, 0.35, 1] }}
                                                        transition={{ duration: 1.1, repeat: Infinity }}
                                                    />
                                                    {/* timer */}
                                                    <span className="shrink-0 font-mono text-[10px] tabular-nums text-white/85">
                                                        {`${Math.floor(seconds / 60)}:${String(
                                                            seconds % 60,
                                                        ).padStart(2, "0")}`}{" "}
                                                        <span className="text-white/40">/ 3:00</span>
                                                    </span>
                                                    {/* live waveform — varied bar
                                                        heights for a natural audio
                                                        look, centered on a midline */}
                                                    <div className="flex shrink-0 items-center gap-[1px]">
                                                        {[
                                                            0.35, 0.55, 0.85, 0.3, 0.45, 0.7, 1,
                                                            0.4, 0.6, 0.95, 0.5, 0.8, 0.35, 0.65,
                                                            0.9, 0.45, 0.3, 0.55,
                                                        ].map((h, i) => (
                                                            <motion.span
                                                                key={i}
                                                                className="w-[1.5px] rounded-full bg-white/70"
                                                                style={{ height: 12 }}
                                                                animate={
                                                                    speaking
                                                                        ? { scaleY: [h * 0.5, h, h * 0.5] }
                                                                        : { scaleY: h }
                                                                }
                                                                transition={
                                                                    speaking
                                                                        ? {
                                                                              duration: 0.7,
                                                                              repeat: Infinity,
                                                                              delay: i * 0.05,
                                                                              ease: "easeInOut",
                                                                          }
                                                                        : { duration: 0.2 }
                                                                }
                                                            />
                                                        ))}
                                                    </div>
                                                </div>
                                                {/* right — controls */}
                                                <div className="flex items-center gap-2">
                                                    {/* cancel — trimmed on the narrowest widths */}
                                                    <span className="hidden shrink-0 items-center gap-1 text-[10px] text-white/40 sm:flex">
                                                        <X className="h-2.5 w-2.5" strokeWidth={2} />
                                                        Cancel
                                                    </span>
                                                    {/* stop button */}
                                                    <span className="flex shrink-0 items-center gap-1 rounded-full bg-red-500 px-2 py-0.5 text-[10px] font-medium text-white">
                                                        <span className="h-1.5 w-1.5 rounded-[1px] bg-white" />
                                                        Stop
                                                    </span>
                                                </div>
                                            </motion.div>
                                            <motion.div
                                                initial={false}
                                                animate={{ opacity: step === 3 ? 1 : 0 }}
                                                transition={{ duration: 0.2 }}
                                                className="flex w-full items-center justify-between [grid-area:1/1]"
                                            >
                                                {/* left — result */}
                                                <div className="flex items-center gap-1.5">
                                                    {/* green check */}
                                                    <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-green-400/15 text-green-400 ring-1 ring-green-400/40">
                                                        <Check className="h-2.5 w-2.5" strokeWidth={3} />
                                                    </span>
                                                    {/* result label */}
                                                    <span className="shrink-0 text-[10px] font-semibold text-white">
                                                        Changes applied
                                                    </span>
                                                </div>
                                                {/* right — actions */}
                                                <div className="flex items-center gap-2">
                                                    {/* undo */}
                                                    <span className="shrink-0 text-[10px] font-medium text-red-400">
                                                        Undo
                                                    </span>
                                                    {/* accept button */}
                                                    <span className="shrink-0 rounded-full bg-green-400 px-2.5 py-0.5 text-[10px] font-semibold text-neutral-900">
                                                        Accept
                                                    </span>
                                                </div>
                                            </motion.div>
                                </motion.div>
                            )}
                        </AnimatePresence>
                    </div>
                </div>

                {/* Viewport — the page being recorded */}
                <div className="relative h-72 overflow-hidden rounded-xl bg-[#0a0a0b] ring-1 ring-white/[0.06] sm:h-[21rem] lg:h-[23rem]">
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
                        <div className="relative">
                            <div className="grid grid-cols-3 gap-4">
                            {[0, 1, 2].map((i) => {
                                const target = i === 1;
                                // The middle card is mismatched until corrected.
                                const off = target && !edited;
                                return (
                                    <motion.div
                                        key={i}
                                        className="relative flex flex-col gap-3 rounded-lg p-5"
                                        animate={{
                                            backgroundColor: off
                                                ? "rgba(251,191,36,0.14)"
                                                : "rgba(255,255,255,0.04)",
                                            // The middle card starts undersized and
                                            // grows to match its siblings once fixed.
                                            scale: off ? 0.8 : 1,
                                        }}
                                        transition={{ duration: 0.45 }}
                                    >
                                        <motion.span
                                            className="h-10 w-10 rounded-md"
                                            animate={{
                                                backgroundColor: off
                                                    ? "rgba(251,191,36,0.6)"
                                                    : "rgba(255,255,255,0.15)",
                                            }}
                                            transition={{ duration: 0.45 }}
                                        />
                                        <motion.span
                                            className="block h-2.5 rounded-full"
                                            animate={{
                                                width: off ? "55%" : "100%",
                                                backgroundColor: off
                                                    ? "rgba(251,191,36,0.35)"
                                                    : "rgba(255,255,255,0.10)",
                                            }}
                                            transition={{ duration: 0.45 }}
                                        />
                                        <motion.span
                                            className="block h-2.5 rounded-full"
                                            animate={{
                                                width: off ? "85%" : "66%",
                                                backgroundColor: off
                                                    ? "rgba(251,191,36,0.35)"
                                                    : "rgba(255,255,255,0.10)",
                                            }}
                                            transition={{ duration: 0.45 }}
                                        />
                                    </motion.div>
                                );
                            })}
                            </div>

                            {/* Marquee selection around all three cards. During
                                step 1 it grows from its top-left corner in sync
                                with the cursor drag (scale 0 → 1); for every
                                other step it stays fully drawn over all three. */}
                            <motion.span
                                aria-hidden="true"
                                className="pointer-events-none absolute -inset-2 origin-top-left rounded-xl border border-dashed border-green-400/80 bg-green-400/[0.06]"
                                initial={false}
                                animate={{
                                    scaleX: selecting ? [0, 1] : 1,
                                    scaleY: selecting ? [0, 1] : 1,
                                }}
                                transition={
                                    selecting
                                        ? { duration: 1.4, ease: "easeInOut" }
                                        : { duration: 0.3 }
                                }
                            />
                        </div>

                        {/* Body skeleton */}
                        <div className="space-y-2.5">
                            <span className="block h-2 w-3/4 rounded-full bg-white/10" />
                            <span className="block h-2 w-1/2 rounded-full bg-white/10" />
                        </div>
                    </div>

                    {/* Subtitle — what the user is saying out loud */}
                    <motion.div
                        className="absolute inset-x-3 bottom-3 flex items-center justify-center gap-2.5 rounded-xl bg-black/70 px-4 py-3 backdrop-blur-sm"
                        initial={false}
                        animate={{
                            opacity: showSubtitle ? 1 : 0,
                            y: showSubtitle ? 0 : 8,
                        }}
                        transition={{ duration: 0.3 }}
                    >
                        <Mic className="h-5 w-5 shrink-0 text-green-400" strokeWidth={1.8} />
                        {/* Live waveform while speaking */}
                        <div className="flex shrink-0 items-end gap-[2px]">
                            {[0.5, 0.9, 0.6, 1, 0.55, 0.85].map((h, i) => (
                                <motion.span
                                    key={i}
                                    className="w-[2.5px] rounded-full bg-green-400/80"
                                    style={{ height: 20, originY: 1 }}
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
                        <span className="truncate text-sm text-white/85">
                            &ldquo;Fix this card so it matches the other cards in this section.&rdquo;
                        </span>
                    </motion.div>
                </div>

                {/* Animated cursor — lives at the mock level so it can travel
                    between the cards and the pill in the title bar. It drags the
                    marquee corner, circles the middle card while talking, moves up
                    to the Stop button to end the recording, then drags back down. */}
                <motion.div
                    className="pointer-events-none absolute left-0 top-0 z-30"
                    initial={false}
                    animate={cursorPos}
                    transition={cursorTransition}
                >
                    {/* Through step 2 the cursor traces a small circle over the
                        middle card to "point it out". */}
                    <motion.div
                        animate={
                            speaking || writingSpec
                                ? {
                                      x: [0, 7, 10, 7, 0, -7, -10, -7, 0],
                                      y: [-10, -7, 0, 7, 10, 7, 0, -7, -10],
                                  }
                                : { x: 0, y: 0 }
                        }
                        transition={
                            speaking || writingSpec
                                ? { duration: 1.8, repeat: Infinity, ease: "linear" }
                                : { duration: 0.2 }
                        }
                    >
                        <Cursor />
                    </motion.div>
                </motion.div>
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
            <div className="relative px-4 py-12 sm:py-16">
                {/* Ring visuals mirror the app's DevRingView: a crisp 5px edge
                    line (half visible inside the edge, softened ~2px) plus a
                    soft inward glow, pulsing opacity-only between the 0.70
                    floor and 1.0 on a 1.9s ease-in-out breathe each way (3.8s
                    round trip). The glow band is widened from the app's
                    14px/22px stroke to suit the web section's larger canvas.
                    The shadow itself is static so the pulse is a cheap
                    composited fade rather than a per-frame box-shadow repaint —
                    the web analog of the app's drawingGroup + opacity pulse. */}
                <motion.div
                    aria-hidden="true"
                    className="pointer-events-none absolute inset-0"
                    style={{
                        boxShadow:
                            "inset 0 0 2px 2.5px rgba(34,197,94,0.8), inset 0 0 36px 12px rgba(34,197,94,0.4)",
                    }}
                    animate={{ opacity: [0.7, 1, 0.7] }}
                    transition={{ duration: 3.8, ease: "easeInOut", repeat: Infinity }}
                />
            <div className="mx-auto w-full max-w-7xl">
            {/* Centered section header — eyebrow + heading sit above the hero */}
            <div className="mx-auto mb-10 flex max-w-2xl flex-col items-center gap-3 text-center lg:mb-14">
                <p className="text-sm font-medium uppercase tracking-[0.18em] text-green-400">
                    Dev Mode
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
                <div className="order-1 flex flex-col items-center gap-5 text-center lg:order-2 lg:col-span-2 lg:items-start lg:text-left">
                    <h3 className="max-w-md text-balance text-2xl font-semibold leading-[1.15] tracking-tight text-foreground sm:text-3xl">
                        Build and iterate with a{" "}
                        <span className="text-green-400">single shortcut</span> and your
                        voice.
                    </h3>
                    <p className="max-w-md text-base leading-relaxed text-muted-foreground">
                        Record your screen and say what you want changed. Zerro turns it
                        into a clear, step-by-step plan, then hands it to your coding
                        agent, which makes the edits and updates your site as you watch.
                    </p>
                    {/* Premium callout — a restrained green-tinted card that echoes the
                        active step pill, with the same Mic accent the recorder uses. */}
                    <div className="flex max-w-md items-start gap-3 rounded-xl border border-green-500/20 bg-green-400/[0.05] px-4 py-3.5 text-left">
                        <span className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-green-400/10 text-green-400">
                            <Mic className="h-4 w-4" strokeWidth={1.8} />
                        </span>
                        <p className="text-[15px] font-medium leading-relaxed text-foreground sm:text-base">
                            No more screenshots to explain what you mean. Just describe
                            the change out loud and your coding agent takes it from there.
                        </p>
                    </div>
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
                    Bring your own agent. Zerro auto-detects the CLIs installed on
                    your Mac and runs the one you pick, locally.
                </p>
            </div>
            </div>
            </div>
        </motion.section>
    );
};

export default DevMode;
