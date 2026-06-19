"use client";

import type { SVGProps } from "react";
import { motion } from "motion/react";
import { Mic, ArrowRight, ChevronDown, Check } from "lucide-react";

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

// One step in the screen → spec → edit flow.
type Step = {
    kicker: string;
    title: string;
    body: React.ReactNode;
};

// A small inset panel — same near-black chrome the artifact card uses.
// Fills the height of its column so all three steps line up evenly.
function Panel({ children }: { children: React.ReactNode }) {
    return (
        <div className="relative flex-1 overflow-hidden rounded-xl bg-[#0a0a0b] p-4 ring-1 ring-white/[0.06]">
            {children}
        </div>
    );
}

// Connector between steps — a right arrow on desktop, a down chevron on mobile.
function Connector() {
    return (
        <div
            aria-hidden="true"
            className="flex shrink-0 items-center justify-center text-white/25"
        >
            <ArrowRight className="hidden h-5 w-5 lg:block" strokeWidth={1.6} />
            <ChevronDown className="h-5 w-5 lg:hidden" strokeWidth={1.6} />
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
                    // edges toward the section, instead of a halo radiating out.
                    boxShadow: [
                        "0 0 0 1px rgba(34,197,94,0.20), inset 0 0 40px -10px rgba(34,197,94,0.25)",
                        "0 0 0 1.5px rgba(34,197,94,0.60), inset 0 0 80px -6px rgba(34,197,94,0.55)",
                        "0 0 0 1px rgba(34,197,94,0.20), inset 0 0 40px -10px rgba(34,197,94,0.25)",
                    ],
                }}
                transition={{ duration: 2.4, ease: "easeInOut", repeat: Infinity }}
            >
            <div className="mx-auto w-full max-w-7xl">
            <div className="mb-12 lg:mb-16 flex flex-col items-center gap-3 text-center">
                <p className="text-sm font-medium uppercase tracking-[0.18em] text-green-400">
                    DevMode
                </p>
                <h2 className="text-3xl font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl max-w-2xl leading-tight">
                    Describe the changes,
                    <br />
                    watch them happen.
                </h2>
                <p className="max-w-xl text-lg font-medium tracking-tight text-green-400 sm:text-xl">
                    Build and iterate with just a single shortcut and your voice.
                </p>
                <p className="max-w-xl text-base text-muted-foreground">
                    Record your screen, say what you want changed, and Zerro turns it
                    into a clear, step-by-step plan — then hands it to your coding
                    agent, which makes the edits and updates your site as you watch.
                </p>
                <p className="max-w-xl text-base text-muted-foreground">
                    No more capturing screenshots to explain what you mean — just
                    describe the change out loud and let your coding agent take it
                    from there.
                </p>
            </div>

            <div className="relative mx-auto max-w-5xl">
                {/* Ambient glow behind the illustration */}
                <div
                    aria-hidden="true"
                    className="absolute inset-0 z-0 flex items-center justify-center pointer-events-none"
                >
                    <div
                        className="h-[120%] w-[140%] rounded-[50%] opacity-60 blur-[140px]"
                        style={{
                            background:
                                "radial-gradient(ellipse at center, rgba(255,255,255,0.5), rgba(255,255,255,0) 72%)",
                        }}
                    />
                </div>

                {/* Illustration card — fixed gray chrome in both themes (matches the app) */}
                <div className="relative z-10 overflow-hidden rounded-2xl border border-white/10 bg-[#202022] p-4 shadow-[0_30px_80px_-30px_rgba(0,0,0,0.4)] sm:p-6">
                    <div className="flex flex-col items-stretch gap-3 lg:flex-row lg:items-stretch">
                        {/* Step 1 — Record + dictate */}
                        <div className="flex flex-1 flex-col">
                            <p className="mb-2 text-xs font-medium uppercase tracking-[0.18em] text-white/40">
                                Record &amp; say it
                            </p>
                            <Panel>
                                {/* Mini browser chrome */}
                                <div className="mb-3 flex items-center gap-2">
                                    <span className="h-2 w-2 rounded-full bg-white/20" />
                                    <span className="h-2 w-2 rounded-full bg-white/20" />
                                    <span className="h-2 w-2 rounded-full bg-white/20" />
                                    <span className="ml-2 truncate rounded-md bg-white/[0.06] px-2 py-0.5 font-mono text-[11px] text-white/45">
                                        localhost:3000
                                    </span>
                                </div>
                                {/* Region-selected viewport with mic */}
                                <div className="relative flex h-20 items-center justify-center rounded-lg border border-dashed border-white/15 bg-white/[0.02]">
                                    <span className="absolute left-2 top-2 rounded bg-green-500/90 px-1.5 py-0.5 text-[10px] font-semibold text-white">
                                        REC
                                    </span>
                                    {/* Voice waveform */}
                                    <div className="flex items-center gap-2 text-white/60">
                                        <Mic className="h-4 w-4" strokeWidth={1.8} />
                                        <div className="flex items-end gap-[3px]">
                                            {[6, 12, 8, 16, 10, 14, 7, 13, 9].map((h, i) => (
                                                <span
                                                    key={i}
                                                    className="w-[3px] rounded-full bg-white/40"
                                                    style={{ height: `${h}px` }}
                                                />
                                            ))}
                                        </div>
                                    </div>
                                </div>
                                <p className="mt-3 text-[13px] leading-snug text-white/65">
                                    &ldquo;Make this header sticky and change the CTA to
                                    teal.&rdquo;
                                </p>
                            </Panel>
                        </div>

                        <Connector />

                        {/* Step 2 — Zerro writes the spec */}
                        <div className="flex flex-1 flex-col">
                            <p className="mb-2 text-xs font-medium uppercase tracking-[0.18em] text-white/40">
                                Zerro writes the spec
                            </p>
                            <Panel>
                                <div className="mb-3 flex items-center gap-2">
                                    <span className="flex h-5 w-5 items-center justify-center rounded-md bg-white text-[11px] font-bold text-neutral-900">
                                        Z
                                    </span>
                                    <span className="text-[13px] font-semibold text-white">
                                        Change spec
                                    </span>
                                </div>
                                <ul className="space-y-2 font-mono text-[12px] leading-snug text-white/65">
                                    <li className="flex gap-2">
                                        <span className="shrink-0 text-green-400/70">1.</span>
                                        <span>
                                            Make the top nav{" "}
                                            <span className="text-green-300">position: sticky</span>.
                                        </span>
                                    </li>
                                    <li className="flex gap-2">
                                        <span className="shrink-0 text-green-400/70">2.</span>
                                        <span>Recolor the primary CTA to teal.</span>
                                    </li>
                                    <li className="flex gap-2">
                                        <span className="shrink-0 text-green-400/70">3.</span>
                                        <span>Keep existing layout &amp; spacing.</span>
                                    </li>
                                </ul>
                            </Panel>
                        </div>

                        <Connector />

                        {/* Step 3 — Your agent edits */}
                        <div className="flex flex-1 flex-col">
                            <p className="mb-2 text-xs font-medium uppercase tracking-[0.18em] text-white/40">
                                Your agent edits
                            </p>
                            <Panel>
                                <div className="mb-3 flex items-center gap-2 text-white/70">
                                    <ClaudeMark className="h-4 w-4" />
                                    <span className="text-[13px] font-semibold text-white">
                                        Claude Code
                                    </span>
                                    <span className="ml-auto flex items-center gap-1 text-[11px] text-green-400">
                                        <Check className="h-3 w-3" strokeWidth={3} />
                                        applied
                                    </span>
                                </div>
                                <pre className="overflow-hidden font-mono text-[12px] leading-relaxed">
                                    <span className="text-white/40">Header.tsx</span>
                                    {"\n"}
                                    <span className="text-red-400/80">- className=&quot;relative&quot;</span>
                                    {"\n"}
                                    <span className="text-green-400/90">+ className=&quot;sticky top-0&quot;</span>
                                    {"\n"}
                                    <span className="text-red-400/80">- bg=&quot;indigo&quot;</span>
                                    {"\n"}
                                    <span className="text-green-400/90">+ bg=&quot;teal&quot;</span>
                                </pre>
                            </Panel>
                        </div>
                    </div>
                </div>

                {/* Supported agents */}
                <div className="relative z-10 mt-10">
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
            </div>
            </motion.div>
        </motion.section>
    );
};

export default DevMode;
