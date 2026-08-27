"use client";

import { DownloadButton } from "@/components/download-button";
import { AnimatedBorder } from "@/components/ui/animated-border";
import { BorderTrail } from "@/components/ui/border-trail";
import { Card } from "@/components/ui/card";
import { GradientField } from "@/components/ui/gradient-field";
import { MODEL_VENDORS, SELECTABLE_MODEL_COUNT } from "@/lib/model-registry";
import {
    LICENSED_RELEASES,
    LICENSE_MAC_COUNT,
    LICENSE_PRICE,
    NEXT_MAJOR,
    SOURCE_LICENSE,
    TRIAL_DAYS,
} from "@/lib/product-facts";
import { cn } from "@/lib/utils";
import { Check, Sparkles } from "lucide-react";
import { motion } from "motion/react";

// ─── License card styling ────────────────────────────────────────────────────
// A lifted solid-black card that draws the eye through a teal accent ring +
// soft colored glow rather than brightness, with accents pulled from the
// pricing section's blue→teal→purple gradient so nothing clashes. Collected
// here so every accent-dependent element stays consistent.
const CARD_STYLE = {
    card:
        "border-transparent bg-black text-foreground " +
        "lg:p-7 ring-1 ring-[#28a082]/40 " +
        // a tinted ring + outer colored glow reads cleanly and is cheap (a true
        // gradient border would need a masked padding-box/border-box layer).
        "shadow-[0_0_0_1px_rgba(40,160,130,0.34),0_46px_110px_-20px_rgba(40,160,130,0.46)]",
    title: "text-foreground",
    // "One-time" badge — solid white against the black card.
    badge: "bg-white text-neutral-900",
    blurb: "text-muted-foreground",
    price: "text-foreground",
    cadence: "text-foreground/65",
    check: "text-[#5fd6b4]",
    feature: "text-foreground/90",
    note: "text-muted-foreground",
} as const;

// A feature is either a plain bullet, or a bullet with a smaller muted
// sub-line beneath it.
type Feature = string | { label: string; note: string };

// The one thing Zerro sells: a license for the official signed and notarized
// build. Every fact here comes from lib/product-facts so the FAQ and JSON-LD
// quote the same numbers.
const license: {
    name: string;
    badge: string;
    blurb: string;
    price: string;
    cadence: string;
    features: Feature[];
} = {
    name: "Zerro License",
    badge: "One-time",
    blurb: "The official signed and notarized Zerro build. Pay once, use your own keys.",
    price: LICENSE_PRICE,
    cadence: "one-time",
    features: [
        {
            label: `${TRIAL_DAYS}-day free trial`,
            note: "No card, no account. Starts the first time an official build runs on your Mac.",
        },
        `Use on up to ${LICENSE_MAC_COUNT} Macs at once`,
        `All Zerro ${LICENSED_RELEASES} updates included`,
        "Bring your own OpenAI, Gemini & Anthropic API keys",
        `All ${SELECTABLE_MODEL_COUNT} models: ${MODEL_VENDORS}`,
        "Keys stay in your macOS Keychain",
        "Frames and transcript go straight to your provider, never through Zerro's servers",
        "No subscription, no account",
    ],
};

const Pricing = () => {
    return (
        <motion.section
            id="pricing"
            className="relative mx-auto w-full max-w-7xl px-4 py-16 lg:py-20"
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.15 }}
            transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
        >
            {/* Full-bleed solid gradient surface — makes the pricing section stand out */}
            <GradientField
                solid
                edgeFade="none"
                className="top-0 bottom-0 left-1/2 -translate-x-1/2 z-0 w-screen"
            />

            <div className="relative z-10 mb-5 lg:mb-7 flex flex-col items-center gap-3 text-center">
                <p className="text-sm font-medium uppercase tracking-[0.18em] text-primary">
                    Pricing
                </p>
                <h2 className="text-3xl font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl max-w-2xl leading-tight">
                    One license. Your keys. No subscription.
                </h2>
                <p className="max-w-xl text-base text-muted-foreground">
                    Try the official build free for {TRIAL_DAYS} days, then pay once. Your AI
                    provider bills you directly for usage.
                </p>
            </div>

            {/* Primary download CTA — one cohesive, centered group lifted above the
                card: the button leads as the primary action, with the "Start…"
                line directly beneath it as supporting reassurance microcopy. */}
            <div className="relative z-10 mb-8 lg:mb-10 flex flex-col items-center gap-3.5">
                <DownloadButton
                    placement="pricing"
                    className="relative gap-2 rounded-full hover:border-border hover:bg-muted hover:text-foreground hover:backdrop-blur-md dark:hover:border-input dark:hover:bg-input/30 dark:hover:text-foreground"
                    size="lg"
                >
                    <AnimatedBorder />
                    <Sparkles className="h-4 w-4" strokeWidth={2} />
                    Try it free
                </DownloadButton>
                <p className="text-center text-sm font-medium text-muted-foreground">
                    Start your {TRIAL_DAYS}-day free trial. No card, no account.
                </p>
            </div>

            {/* The single license card, centered. */}
            <div className="relative z-10 mt-8 lg:mt-10 mx-auto w-full max-w-md">
                <motion.div
                    initial={{ opacity: 0, y: 16 }}
                    whileInView={{ opacity: 1, y: 0 }}
                    viewport={{ once: true, amount: 0.3 }}
                    transition={{ duration: 0.4, ease: [0.25, 0.46, 0.45, 0.94] }}
                    className="relative z-10 h-full"
                >
                    <Card className={cn("relative flex h-full flex-col gap-5 p-6", CARD_STYLE.card)}>
                        {/* Border trail — a teal traveling segment matching the
                            card's accent ring. */}
                        <div className="pointer-events-none absolute inset-0 rounded-[inherit]">
                            <BorderTrail
                                size={80}
                                className="bg-gradient-to-r from-transparent via-[#28a082] to-transparent blur-[1px]"
                                transition={{ repeat: Infinity, duration: 6, ease: "linear" }}
                            />
                        </div>

                        {/* Badge sits on its own row at the top */}
                        <div className="flex items-center justify-between">
                            <h3 className={cn("text-xl font-medium tracking-tight", CARD_STYLE.title)}>
                                {license.name}
                            </h3>
                            <span
                                className={cn(
                                    "shrink-0 rounded-full px-2.5 py-0.5 text-sm font-medium uppercase tracking-wider",
                                    CARD_STYLE.badge
                                )}
                            >
                                {license.badge}
                            </span>
                        </div>

                        <p className={cn("text-sm -mt-3", CARD_STYLE.blurb)}>{license.blurb}</p>

                        <div className="flex items-baseline gap-2 flex-wrap">
                            <span className={cn("text-4xl lg:text-5xl font-medium tracking-tighter", CARD_STYLE.price)}>
                                {license.price}
                            </span>
                            <span className={cn("text-sm", CARD_STYLE.cadence)}>{license.cadence}</span>
                        </div>

                        <ul className="flex flex-col gap-2.5 flex-grow">
                            {license.features.map((f) => {
                                const label = typeof f === "string" ? f : f.label;
                                const note = typeof f === "string" ? undefined : f.note;
                                return (
                                    <li key={label} className="flex items-start gap-3">
                                        <Check
                                            className={cn("mt-0.5 h-4 w-4 flex-shrink-0", CARD_STYLE.check)}
                                            strokeWidth={2.4}
                                        />
                                        <span className={cn("text-sm leading-relaxed", CARD_STYLE.feature)}>
                                            {label}
                                            {note && (
                                                <span className={cn("mt-0.5 block text-xs leading-relaxed", CARD_STYLE.note)}>
                                                    {note}
                                                </span>
                                            )}
                                        </span>
                                    </li>
                                );
                            })}
                        </ul>
                    </Card>
                </motion.div>
            </div>

            {/* Honest privacy distinction — a genuine selling point, not buried.
                Bumped to foreground/75 so it clears AA contrast over the gradient surface. */}
            <p className="relative z-10 mt-8 mx-auto max-w-2xl text-center text-sm text-foreground/75">
                Zerro never receives your recordings. Your Mac prepares them, then sends
                the frames and transcript straight to the AI provider you choose on your
                own API key, and that provider bills you for the usage.
            </p>

            <p className="relative z-10 mt-4 mx-auto max-w-2xl text-center text-sm text-foreground/60">
                Prices listed in USD. The license covers every Zerro {LICENSED_RELEASES}{" "}
                release; a future {NEXT_MAJOR} major release may be sold separately.
                Zerro is free software under {SOURCE_LICENSE}: build it from the source
                yourself and no Zerro license is required. The {LICENSE_PRICE} pays for the
                official signed and notarized build, its {LICENSED_RELEASES} update
                service, and support.
            </p>
        </motion.section>
    );
};

export default Pricing;
