"use client";

import { motion } from "motion/react";
import { Copy, Check, FileText, ChevronUp } from "lucide-react";

export default function ToolFeature() {
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
                <p className="text-xs font-medium uppercase tracking-[0.18em] text-primary">
                    The output
                </p>
                <h2 className="text-3xl font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl max-w-2xl leading-tight">
                    The prompt writes itself.
                </h2>
                <p className="max-w-xl text-base text-muted-foreground">
                    Structured Markdown your agent can actually act on — not a one-liner you&apos;ll have to follow up on three times.
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

                {/* Prompt card — fixed gray chrome in both themes (matches the app) */}
                <div className="relative z-10 overflow-hidden rounded-2xl border border-white/10 bg-[#202022] shadow-[0_30px_80px_-30px_rgba(0,0,0,0.4)]">
                    {/* Top bar — status + actions */}
                    <div className="flex items-center justify-between px-5 py-3.5">
                        <div className="flex items-center gap-2.5">
                            <span className="flex h-5 w-5 items-center justify-center rounded-full bg-green-500">
                                <Check className="h-3 w-3 text-white" strokeWidth={3} />
                            </span>
                            <span className="text-[15px] font-semibold text-white">
                                Prompt ready
                            </span>
                        </div>
                        <div className="flex items-center gap-4">
                            <button className="flex items-center gap-2 rounded-full bg-white px-4 py-1.5 text-sm font-medium text-neutral-900 transition-colors hover:bg-white/90">
                                <Copy className="h-3.5 w-3.5" />
                                Copy
                            </button>
                            <button className="flex items-center gap-1 text-sm text-white/50 transition-colors hover:text-white/80">
                                Hide
                                <ChevronUp className="h-4 w-4" />
                            </button>
                        </div>
                    </div>

                    {/* Sub-header — file label */}
                    <div className="flex items-center gap-2 border-t border-white/[0.07] px-5 py-3">
                        <FileText className="h-3.5 w-3.5 text-white/40" />
                        <span className="font-mono text-[11px] uppercase tracking-wider text-white/40">
                            Structured prompt · Markdown
                        </span>
                    </div>

                    {/* Markdown body — inset near-black panel framed by the gray chrome */}
                    <div className="px-3 pb-3">
                        <div className="space-y-5 rounded-xl bg-[#0a0a0b] px-6 py-7 font-mono text-[13px] leading-relaxed text-white/80 ring-1 ring-white/[0.06] lg:px-8">
                            <div>
                                <p className="font-semibold text-white">## Context</p>
                                <p className="mt-1.5 text-white/65">
                                    Reviewing the sign-in screen for a SaaS dashboard. Authenticated user lands here from marketing; conversion is the priority.
                                </p>
                            </div>
                            <div>
                                <p className="font-semibold text-white">## Current State</p>
                                <ul className="mt-1.5 space-y-1 text-white/65">
                                    <li>- &quot;Forgot password?&quot; link sits below the form, separated by helper copy</li>
                                    <li>- Helper copy wraps to three lines on mobile</li>
                                    <li>- Primary CTA uses a muted gray rather than the brand blue</li>
                                    <li>- Tab order skips the &quot;Remember me&quot; checkbox</li>
                                </ul>
                            </div>
                            <div>
                                <p className="font-semibold text-white">## Request</p>
                                <p className="mt-1.5 text-white/65">
                                    Move &quot;Forgot password?&quot; into the Sign In cluster directly below the password field. Tighten helper copy to a single line. Promote the primary CTA to brand blue and fix the tab order so &quot;Remember me&quot; is reachable.
                                </p>
                            </div>
                        </div>
                    </div>
                </div>

                <p className="mt-6 text-center text-xs text-muted-foreground">
                    Example output. Every prompt is generated from your real recording.
                </p>
            </div>
        </motion.section>
    );
}
