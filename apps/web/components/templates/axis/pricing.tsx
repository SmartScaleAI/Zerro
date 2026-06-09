"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { AnimatedBorder } from "@/components/ui/animated-border";
import { BorderTrail } from "@/components/ui/border-trail";
import { Card } from "@/components/ui/card";
import { GradientField } from "@/components/ui/gradient-field";
import { DOWNLOAD_URL } from "@/lib/site-config";
import { cn } from "@/lib/utils";
import { Check, Sparkles } from "lucide-react";
import { AppleIcon } from "@/components/ui/apple-icon";
import { AnimatePresence, motion } from "motion/react";

type Billing = "monthly" | "yearly";

type Tier = {
    name: string;
    blurb: string;
    // Subscription tiers carry monthly/yearly prices that react to the toggle.
    // The one-time tier (BYOK) uses `price` + `cadence` and ignores the toggle.
    monthly?: { price: string; yearly: string; yearlyNote: string };
    price?: string;
    cadence?: string;
    badge: string;
    features: string[];
    cta: { label: string; variant: "primary" | "outline" };
    highlight?: boolean;
};

const tiers: Tier[] = [
    {
        name: "Starter",
        blurb: "We handle the AI — no keys, no setup.",
        monthly: { price: "$12", yearly: "$120", yearlyNote: "2 months free" },
        badge: "Available now",
        features: [
            "15 free generations to start",
            "Up to 100 recordings / month",
            "No API key required",
            "Monthly credits included",
            "We manage all token usage",
            "Cancel anytime",
        ],
        cta: { label: "Download for macOS", variant: "primary" },
    },
    {
        name: "Pro",
        blurb: "For heavy or daily use.",
        monthly: { price: "$29", yearly: "$290", yearlyNote: "2 months free" },
        badge: "Most popular",
        features: [
            "Everything in Starter, plus…",
            "Up to 300 recordings / month",
            "15 free generations to start",
        ],
        cta: { label: "Download for macOS", variant: "primary" },
        highlight: true,
    },
    {
        name: "BYOK",
        blurb: "Pay once. Bring your own key. Runs fully on your Mac.",
        price: "$39",
        cadence: "one-time",
        badge: "Available now",
        features: [
            "15 free generations to start",
            "All features and future updates",
            "Bring your own OpenAI API key",
            "Keys stored in your macOS Keychain",
            "Recordings never leave your Mac",
            "No subscription, no account",
        ],
        cta: { label: "Download for macOS", variant: "primary" },
    },
];

const Pricing = () => {
    const [billing, setBilling] = useState<Billing>("monthly");

    return (
        <motion.section
            id="pricing"
            className="relative mx-auto w-full max-w-7xl px-4 py-20 lg:py-28"
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

            <div className="relative z-10 mb-8 lg:mb-10 flex flex-col items-center gap-3 text-center">
                <p className="text-sm font-medium uppercase tracking-[0.18em] text-primary">
                    Pricing
                </p>
                <h2 className="text-3xl font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl max-w-2xl leading-tight">
                    Pay once, or let us handle it.
                </h2>
                <p className="max-w-xl text-base text-muted-foreground">
                    Try it free, then choose the path that fits — we handle the AI, or you bring your own key.
                </p>
            </div>

            {/* Trial lead-in — applies to every path. Not a card, just a prominent hook. */}
            <div className="relative z-10 mb-8 flex justify-center">
                <span className="inline-flex items-center gap-2 rounded-full bg-primary/10 px-4 py-1.5 text-sm font-medium text-primary">
                    <Sparkles className="h-4 w-4" strokeWidth={2} />
                    Start free — 15 generations. No card, no key, no time limit.
                </span>
            </div>

            {/* Monthly / yearly toggle — drives the two Managed (subscription) cards. */}
            <div className="relative z-10 mb-10 flex items-center justify-center gap-3">
                <div className="inline-flex items-center gap-1 rounded-full bg-muted p-1 text-sm">
                    {(["monthly", "yearly"] as const).map((option) => (
                        <button
                            key={option}
                            type="button"
                            onClick={() => setBilling(option)}
                            className={cn(
                                "rounded-full px-4 py-1.5 font-medium capitalize transition-colors",
                                billing === option
                                    ? "bg-white text-neutral-900 shadow-xs"
                                    : "text-muted-foreground hover:text-foreground"
                            )}
                            aria-pressed={billing === option}
                        >
                            {option}
                        </button>
                    ))}
                </div>
                <span className="rounded-full bg-primary/10 px-2.5 py-0.5 text-sm font-medium text-primary">
                    Save ~17%
                </span>
            </div>

            <div className="relative z-10 grid grid-cols-1 items-stretch gap-4 lg:grid-cols-3 lg:gap-6 max-w-6xl mx-auto">
                {tiers.map((tier, i) => {
                    const isSubscription = !!tier.monthly;
                    const showYearly = isSubscription && billing === "yearly";
                    const price = isSubscription
                        ? showYearly
                            ? tier.monthly!.yearly
                            : tier.monthly!.price
                        : tier.price;
                    const cadence = isSubscription
                        ? showYearly
                            ? "per year"
                            : "per month"
                        : tier.cadence;

                    return (
                        <motion.div
                            key={tier.name}
                            initial={{ opacity: 0, y: 16 }}
                            whileInView={{ opacity: 1, y: 0 }}
                            viewport={{ once: true, amount: 0.3 }}
                            transition={{
                                duration: 0.4,
                                delay: i * 0.08,
                                ease: [0.25, 0.46, 0.45, 0.94],
                            }}
                            className={cn(
                                tier.highlight
                                    ? "relative z-10 h-full lg:scale-[1.04]"
                                    : "z-0 h-full"
                            )}
                        >
                            <Card
                                className={cn(
                                    "relative flex h-full flex-col gap-6 p-7",
                                    tier.highlight
                                        ? "border-white/10 bg-white text-neutral-900 shadow-[0_40px_100px_-20px_rgba(0,0,0,0.55)] lg:p-8"
                                        : "border-border bg-card/60"
                                )}
                            >
                                {/* Border trail — highlighted (white) card only */}
                                {tier.highlight && (
                                    <div className="pointer-events-none absolute inset-0 rounded-[inherit]">
                                        <BorderTrail
                                            size={80}
                                            className="bg-gradient-to-r from-transparent via-neutral-400 to-transparent blur-[1px]"
                                            transition={{ repeat: Infinity, duration: 6, ease: "linear" }}
                                        />
                                    </div>
                                )}

                                {/* Badge sits on its own row at the top */}
                                <div className="flex items-center justify-between">
                                    <h3 className={cn("text-xl font-medium tracking-tight", tier.highlight ? "text-neutral-900" : "text-foreground")}>
                                        {tier.name}
                                    </h3>
                                    <span
                                        className={cn(
                                            "shrink-0 rounded-full px-2.5 py-0.5 text-sm font-medium uppercase tracking-wider",
                                            tier.highlight
                                                ? "bg-neutral-900 text-white"
                                                : "border border-border bg-muted text-muted-foreground"
                                        )}
                                    >
                                        {tier.badge}
                                    </span>
                                </div>

                                <p className={cn("text-sm -mt-3", tier.highlight ? "text-neutral-500" : "text-muted-foreground")}>{tier.blurb}</p>

                                <div className="flex items-baseline gap-2 flex-wrap">
                                    <AnimatePresence mode="popLayout" initial={false}>
                                        <motion.span
                                            key={price}
                                            initial={{ opacity: 0, y: 6 }}
                                            animate={{ opacity: 1, y: 0 }}
                                            exit={{ opacity: 0, y: -6 }}
                                            transition={{ duration: 0.18, ease: [0.25, 0.46, 0.45, 0.94] }}
                                            className={cn("text-4xl lg:text-5xl font-medium tracking-tighter", tier.highlight ? "text-neutral-900" : "text-foreground")}
                                        >
                                            {price}
                                        </motion.span>
                                    </AnimatePresence>
                                    <span className={cn("text-sm", tier.highlight ? "text-neutral-600" : "text-foreground/65")}>{cadence}</span>
                                    {showYearly && (
                                        <span className="rounded-full bg-primary/10 px-2 py-0.5 text-sm font-medium text-primary">
                                            {tier.monthly!.yearlyNote}
                                        </span>
                                    )}
                                </div>

                                <ul className="flex flex-col gap-3 flex-grow">
                                    {tier.features.map((f) => (
                                        <li key={f} className="flex items-start gap-3">
                                            <Check
                                                className={cn(
                                                    "mt-0.5 h-4 w-4 flex-shrink-0",
                                                    tier.highlight ? "text-neutral-900" : "text-muted-foreground"
                                                )}
                                                strokeWidth={2.4}
                                            />
                                            <span className={cn("text-sm leading-relaxed", tier.highlight ? "text-neutral-700" : "text-foreground/85")}>
                                                {f}
                                            </span>
                                        </li>
                                    ))}
                                </ul>

                                <Button
                                    className={cn(
                                        "relative w-full rounded-full gap-2",
                                        // Standard (dark) cards: filled primary CTA with the hover/blur treatment.
                                        !tier.highlight &&
                                            "hover:bg-muted hover:text-foreground hover:border-border hover:backdrop-blur-md dark:hover:bg-input/30 dark:hover:text-foreground dark:hover:border-input",
                                        // Pro (white card): a solid black button with white text at rest,
                                        // with a light-gray hover fill (text flips dark to stay legible),
                                        // a gray border on hover, and the tinted animated border accent.
                                        tier.highlight &&
                                            "border-transparent bg-neutral-900 text-white hover:border-neutral-300 hover:bg-neutral-100 hover:text-neutral-900 dark:border-transparent dark:bg-neutral-900 dark:text-white dark:hover:border-neutral-300 dark:hover:bg-neutral-100 dark:hover:text-neutral-900"
                                    )}
                                    size="lg"
                                    variant={tier.cta.variant === "primary" ? "default" : "outline"}
                                    nativeButton={false}
                                    render={<a href={DOWNLOAD_URL} download />}
                                >
                                    {tier.highlight ? (
                                        // Pro: same animated border as the standard cards, but the
                                        // traveling segment is tinted with the hero section's gradient
                                        // (blue → teal → purple), so it reads on the white card.
                                        <AnimatedBorder className="from-transparent from-10% via-[#28a082] via-60% to-[#8c3cc8]" />
                                    ) : (
                                        <AnimatedBorder />
                                    )}
                                    <AppleIcon className="h-4 w-4" />
                                    {tier.cta.label}
                                </Button>
                            </Card>
                        </motion.div>
                    );
                })}
            </div>

            {/* Honest privacy distinction — a genuine selling point, not buried.
                Bumped to foreground/75 so it clears AA contrast over the gradient surface. */}
            <p className="relative z-10 mt-10 mx-auto max-w-2xl text-center text-sm text-foreground/75">
                Starter &amp; Pro send your recording to Zerro&apos;s server to generate the prompt.
                Bring-your-own-key stays fully on your Mac — recordings never leave your machine.
            </p>

            <p className="relative z-10 mt-4 text-center text-sm text-foreground/60">
                Prices listed in USD. The one-time BYOK purchase includes all v1 features and updates.
            </p>
        </motion.section>
    );
};

export default Pricing;
