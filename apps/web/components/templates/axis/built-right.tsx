"use client";

import { motion } from "motion/react";
import { Cpu, Lock, KeyRound, Timer, ShieldCheck, RefreshCw } from "lucide-react";

type Item = {
    icon: React.ComponentType<{ className?: string; strokeWidth?: number }>;
    title: string;
    description: string;
};

const items: Item[] = [
    {
        icon: Cpu,
        title: "Native Swift & SwiftUI",
        description:
            "A real menu-bar app, built on ScreenCaptureKit. Not an Electron tab pretending to be a Mac app.",
    },
    {
        icon: Lock,
        title: "Local-first processing",
        description:
            "Your Mac prepares the recording and redacts sensitive info before anything leaves. Managed sends it to an AI provider; BYOK sends it straight with your key. No Zerro servers.",
    },
    {
        icon: KeyRound,
        title: "Bring your own key",
        description:
            "On BYOK, your OpenAI, Gemini & Anthropic keys are stored in macOS Keychain and recordings go straight to your provider on your own key, never through Zerro's servers.",
    },
    {
        icon: Timer,
        title: "Cost-bounded by design",
        description:
            "A 3-minute hard cap on every recording keeps each request fast, cheap, and predictable.",
    },
    {
        icon: ShieldCheck,
        title: "Signed & notarized",
        description:
            "Distributed direct as a code-signed .dmg. macOS Gatekeeper will not complain.",
    },
    {
        icon: RefreshCw,
        title: "Sparkle auto-updates",
        description:
            "Updates ship through Sparkle, the standard for indie Mac apps. You stay current without thinking about it.",
    },
];

const BuiltRight = () => {
    return (
        <motion.section
            id="built-right"
            className="relative mx-auto max-w-7xl px-4 scroll-mt-24"
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.15 }}
            transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
        >
            <div className="mb-12 lg:mb-16 flex flex-col items-center gap-3 text-center">
                <p className="text-sm font-medium uppercase tracking-[0.18em] text-primary">
                    Built right
                </p>
                <h2 className="text-3xl font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl max-w-2xl leading-tight">
                    Native, local-first, no surprises.
                </h2>
                <p className="max-w-xl text-base text-muted-foreground">
                    Zerro is built the way you&apos;d build it if it were your tool.
                </p>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-px bg-border rounded-2xl overflow-hidden border border-border">
                {items.map((item, i) => {
                    const Icon = item.icon;
                    return (
                        <motion.div
                            key={item.title}
                            initial={{ opacity: 0, y: 12 }}
                            whileInView={{ opacity: 1, y: 0 }}
                            viewport={{ once: true, amount: 0.3 }}
                            transition={{
                                duration: 0.4,
                                delay: i * 0.05,
                                ease: [0.25, 0.46, 0.45, 0.94],
                            }}
                            className="flex flex-col gap-4 bg-background p-8"
                        >
                            <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10 text-primary">
                                <Icon className="h-5 w-5" strokeWidth={1.6} />
                            </div>
                            <h3 className="text-base font-medium text-foreground tracking-tight">
                                {item.title}
                            </h3>
                            <p className="text-sm leading-relaxed text-muted-foreground">
                                {item.description}
                            </p>
                        </motion.div>
                    );
                })}
            </div>
        </motion.section>
    );
};

export default BuiltRight;
