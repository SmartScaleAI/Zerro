"use client";

import { useState } from "react";
import { DownloadButton } from "@/components/download-button";
import { AnimatedBorder } from "@/components/ui/animated-border";
import { BorderTrail } from "@/components/ui/border-trail";
import { Card } from "@/components/ui/card";
import { GradientField } from "@/components/ui/gradient-field";
import { track } from "@/lib/analytics";
import { cn } from "@/lib/utils";
import { Check, Sparkles } from "lucide-react";
import { AppleIcon } from "@/components/ui/apple-icon";
import { AnimatePresence, motion } from "motion/react";

type Billing = "monthly" | "yearly";

// ─── Highlighted (Managed) card styling ──────────────────────────────────────
// The Managed card used to be solid white, which was blinding on the dark site.
// Instead it's a lifted dark-gray card that draws the eye through a teal accent
// ring + soft colored glow rather than brightness, with accents pulled from the
// pricing section's blue→teal→purple gradient so nothing clashes. Collected here
// so every highlight-dependent element stays consistent; the dark (BYOK)
// styling is unchanged and lives inline below.
const HIGHLIGHT_STYLE = {
    // Solid black surface so it stands apart from the frosted-glass BYOK card.
    // It still leads the eye through the teal accent ring + soft colored glow and
    // the gradient badge — the contrast is value (deep black vs. gray glass), not
    // brightness.
    card:
        "border-transparent bg-black text-foreground " +
        "lg:p-7 ring-1 ring-[#28a082]/40 " +
        // a tinted ring + outer colored glow reads cleanly and is cheap (a true
        // gradient border would need a masked padding-box/border-box layer).
        "shadow-[0_0_0_1px_rgba(40,160,130,0.25),0_40px_100px_-20px_rgba(40,160,130,0.30)]",
    title: "text-foreground",
    // "Most popular" badge — solid white (the limited-offer ribbon now carries
    // the blue→teal→purple gradient instead).
    badge: "bg-white text-neutral-900",
    // Floating "Limited offer" ribbon that straddles the card's top edge.
    limitedBadge: "bg-gradient-to-r from-[#5aa0ff] via-[#28a082] to-[#8c3cc8] text-white",
    blurb: "text-muted-foreground",
    toggleTrack: "bg-white/15",
    toggleActive: "bg-white text-neutral-900 shadow-xs",
    toggleInactive: "text-muted-foreground hover:text-foreground",
    saveBadge: "bg-white/15 text-foreground",
    price: "text-foreground",
    cadence: "text-foreground/65",
    yearlyTotal: "bg-white/15 text-foreground",
    check: "text-[#5fd6b4]",
    feature: "text-foreground/90",
    note: "text-muted-foreground",
    // Solid white at rest; on hover it goes transparent with a simple gray border
    // (matching the BYOK button's hover) and the existing rotating glow slides
    // over that border. Defined for both default + dark so it survives either theme.
    button:
        "border border-transparent bg-white text-neutral-900 transition-colors " +
        "hover:bg-transparent hover:text-foreground hover:border-border " +
        "dark:bg-white dark:text-neutral-900 " +
        "dark:hover:bg-transparent dark:hover:text-foreground dark:hover:border-input",
    /** Tailwind gradient stops for the CTA's animated border accent. */
    animatedBorder: "from-transparent from-10% via-[#28a082] via-60% to-[#8c3cc8]",
} as const;

type Tier = {
    name: string;
    blurb: string;
    // Subscription tiers carry monthly/yearly prices that react to the toggle.
    // `price` is the standard monthly rate; on the yearly toggle the big number
    // becomes `yearlyMonthly` (the discounted per-month rate) — still shown as
    // "per month" — and `yearlyTotal` (the full annual charge) moves to the badge.
    // The one-time tier (BYOK) uses `price` + `cadence` and ignores the toggle.
    monthly?: {
        price: string;
        yearlyMonthly: string;
        yearlyTotal: string;
        // Limited-offer "was" prices, struck through beside the active price.
        // compareMonthly is a full per-month string ("$25 per month");
        // compareYearlyTotal mirrors yearlyTotal's "$N billed yearly" framing.
        compareMonthly?: string;
        compareYearlyTotal?: string;
    };
    price?: string;
    cadence?: string;
    badge?: string;
    // Renders a "Limited offer" urgency badge on the card (highlighted tier only).
    limitedOffer?: boolean;
    // A feature is either a plain bullet, or a bullet with a smaller muted
    // sub-line beneath it (e.g. translating an abstract credit count into
    // concrete generations per model).
    features: (string | { label: string; note: string })[];
    cta: { label: string; variant: "primary" | "outline" };
    highlight?: boolean;
    // `placement` value sent with download_clicked for this card's CTA.
    placement: string;
};

// Order matters: cards render left-to-right in array order. The highlighted
// Managed plan (the primary, recommended path) leads on the left; BYOK second.
const tiers: Tier[] = [
    {
        name: "Managed",
        blurb: "We handle the AI — no keys, no setup.",
        monthly: {
            price: "$15",
            yearlyMonthly: "$12",
            yearlyTotal: "$144 billed yearly",
            // Limited-offer comparison: full price $25/mo → $300/yr.
            compareMonthly: "$25 per month",
            compareYearlyTotal: "$300 billed yearly",
        },
        badge: "Most popular",
        limitedOffer: true,
        features: [
            "40 free credits to start",
            {
                label: "300 credits per month",
                note: "≈ 75 generations with Gemini 3.5 Flash, or ~30 with Claude Opus.",
            },
            "6 models to choose from — Claude, GPT & Gemini",
            "Top up anytime — Boost (200 credits, $10) or Power (500 credits, $22)",
            "We manage all token usage — no API keys",
            "Cancel anytime",
        ],
        cta: { label: "Download for macOS", variant: "primary" },
        highlight: true,
        placement: "pricing_managed",
    },
    {
        name: "BYOK",
        blurb: "Bring your own keys. Runs fully on your Mac.",
        price: "$69",
        cadence: "one-time",
        features: [
            "40 free credits to start",
            "Includes 1 year of updates — your installed version keeps working after",
            "Bring your own OpenAI, Gemini & Anthropic API keys",
            "All 6 models — Claude, GPT & Gemini",
            "Keys stored in your macOS Keychain",
            "Recordings never leave your Mac",
            "No subscription, no account",
        ],
        cta: { label: "Download for macOS", variant: "primary" },
        placement: "pricing_byok",
    },
];

const Pricing = () => {
    const [billing, setBilling] = useState<Billing>("yearly");

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
                    Let us handle the AI — or bring your own keys.
                </h2>
                <p className="max-w-xl text-base text-muted-foreground">
                    Try it free, then choose the path that fits — we handle the AI, or you bring your own key.
                </p>
            </div>

            {/* Trial lead-in — applies to every path. Not a card, just a prominent
                hook. Extra bottom margin lifts it clear of the Managed card's
                "Limited offer" ribbon, which straddles the card's top edge. */}
            <div className="relative z-10 mb-12 lg:mb-16 flex justify-center">
                <span className="inline-flex items-center gap-2 rounded-full bg-primary/10 px-4 py-1.5 text-sm font-medium text-primary">
                    <Sparkles className="h-4 w-4" strokeWidth={2} />
                    Start free — 40 credits. No card, no key, no time limit.
                </span>
            </div>

            <div className="relative z-10 grid grid-cols-1 items-stretch gap-4 lg:grid-cols-2 lg:gap-6 max-w-4xl mx-auto">
                {tiers.map((tier, i) => {
                    const isSubscription = !!tier.monthly;
                    const showYearly = isSubscription && billing === "yearly";
                    // Yearly keeps the per-month framing: the big number drops to
                    // the discounted monthly rate, still labeled "per month", and the
                    // full annual charge moves into the badge on the right.
                    const price = isSubscription
                        ? showYearly
                            ? tier.monthly!.yearlyMonthly
                            : tier.monthly!.price
                        : tier.price;
                    const cadence = isSubscription ? "per month" : tier.cadence;

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
                            {/* Limited-offer ribbon — lives on the wrapper (not the Card,
                                which is overflow-hidden) so it can straddle the top edge:
                                centered, half above the card and half over its border. */}
                            {tier.limitedOffer && (
                                <span
                                    className={cn(
                                        "absolute left-1/2 top-0 z-30 -translate-x-1/2 -translate-y-1/2 whitespace-nowrap rounded-full px-3 py-1 text-sm font-semibold uppercase tracking-wider shadow-lg",
                                        HIGHLIGHT_STYLE.limitedBadge
                                    )}
                                >
                                    Limited offer
                                </span>
                            )}
                            <Card
                                className={cn(
                                    "relative flex h-full flex-col gap-5 p-6",
                                    tier.highlight
                                        ? HIGHLIGHT_STYLE.card
                                        // BYOK — a frosted-glass card: a low-opacity dark fill so
                                        // the section gradient reads through, a strong backdrop
                                        // blur, and a soft light border + inset top highlight for
                                        // the frosted-pane look. Distinct from the solid-black
                                        // Managed card without competing with it.
                                        : "border-white/10 bg-black/40 backdrop-blur-2xl shadow-[inset_0_1px_0_rgba(255,255,255,0.08),0_24px_60px_-24px_rgba(0,0,0,0.6)]"
                                )}
                            >
                                {/* Border trail — highlighted card only. Teal traveling
                                    segment, matching the card's accent ring. */}
                                {tier.highlight && (
                                    <div className="pointer-events-none absolute inset-0 rounded-[inherit]">
                                        <BorderTrail
                                            size={80}
                                            className="bg-gradient-to-r from-transparent via-[#28a082] to-transparent blur-[1px]"
                                            transition={{ repeat: Infinity, duration: 6, ease: "linear" }}
                                        />
                                    </div>
                                )}

                                {/* Badge sits on its own row at the top */}
                                <div className="flex items-center justify-between">
                                    <h3 className={cn("text-xl font-medium tracking-tight", tier.highlight ? HIGHLIGHT_STYLE.title : "text-foreground")}>
                                        {tier.name}
                                    </h3>
                                    {tier.badge && (
                                        <span
                                            className={cn(
                                                "shrink-0 rounded-full px-2.5 py-0.5 text-sm font-medium uppercase tracking-wider",
                                                tier.highlight
                                                    ? HIGHLIGHT_STYLE.badge
                                                    : "border border-border bg-muted text-muted-foreground"
                                            )}
                                        >
                                            {tier.badge}
                                        </span>
                                    )}
                                </div>

                                <p className={cn("text-sm -mt-3", tier.highlight ? HIGHLIGHT_STYLE.blurb : "text-muted-foreground")}>{tier.blurb}</p>

                                {/* Monthly / yearly toggle — lives inside the subscription
                                    (Managed) card, directly above its price, so it clearly
                                    controls only this card. BYOK ($69 one-time) renders no
                                    toggle. The "Save ~20%" badge applies to yearly only. */}
                                {isSubscription && (
                                    <div className="-mb-2 flex items-center gap-2">
                                        <div
                                            className={cn(
                                                "inline-flex items-center gap-1 rounded-full p-1 text-sm",
                                                tier.highlight ? HIGHLIGHT_STYLE.toggleTrack : "bg-muted"
                                            )}
                                        >
                                            {(["monthly", "yearly"] as const).map((option) => (
                                                <button
                                                    key={option}
                                                    type="button"
                                                    onClick={() => {
                                                        setBilling(option);
                                                        track("pricing_billing_toggled", { interval: option });
                                                    }}
                                                    className={cn(
                                                        "rounded-full px-3 py-1 font-medium capitalize transition-colors",
                                                        billing === option
                                                            ? tier.highlight
                                                                ? HIGHLIGHT_STYLE.toggleActive
                                                                : "bg-white text-neutral-900 shadow-xs"
                                                            : tier.highlight
                                                                ? HIGHLIGHT_STYLE.toggleInactive
                                                                : "text-muted-foreground hover:text-foreground"
                                                    )}
                                                    aria-pressed={billing === option}
                                                >
                                                    {option}
                                                </button>
                                            ))}
                                        </div>
                                        <span
                                            className={cn(
                                                "rounded-full px-2.5 py-0.5 text-sm font-medium",
                                                tier.highlight ? HIGHLIGHT_STYLE.saveBadge : "bg-primary/10 text-primary"
                                            )}
                                        >
                                            Save ~20%
                                        </span>
                                    </div>
                                )}

                                <div className="flex items-baseline gap-2 flex-wrap">
                                    <AnimatePresence mode="popLayout" initial={false}>
                                        <motion.span
                                            key={price}
                                            initial={{ opacity: 0, y: 6 }}
                                            animate={{ opacity: 1, y: 0 }}
                                            exit={{ opacity: 0, y: -6 }}
                                            transition={{ duration: 0.18, ease: [0.25, 0.46, 0.45, 0.94] }}
                                            className={cn("text-4xl lg:text-5xl font-medium tracking-tighter", tier.highlight ? HIGHLIGHT_STYLE.price : "text-foreground")}
                                        >
                                            {price}
                                        </motion.span>
                                    </AnimatePresence>
                                    <span className={cn("text-sm", tier.highlight ? HIGHLIGHT_STYLE.cadence : "text-foreground/65")}>{cadence}</span>
                                    {showYearly && (
                                        <span className={cn("rounded-full px-2 py-0.5 text-sm font-medium", tier.highlight ? HIGHLIGHT_STYLE.yearlyTotal : "bg-primary/10 text-primary")}>
                                            {tier.monthly!.yearlyTotal}
                                        </span>
                                    )}
                                    {/* Limited-offer "was" price, struck through and muted so it
                                        reads as clearly secondary to the active discounted price.
                                        Monthly compares per-month ($25); yearly compares the full
                                        annual total ($300 billed yearly). */}
                                    {isSubscription &&
                                        (showYearly
                                            ? tier.monthly!.compareYearlyTotal
                                            : tier.monthly!.compareMonthly) && (
                                            <span
                                                className={cn(
                                                    "text-sm line-through",
                                                    tier.highlight ? "text-foreground/45" : "text-muted-foreground/70"
                                                )}
                                            >
                                                {showYearly
                                                    ? tier.monthly!.compareYearlyTotal
                                                    : tier.monthly!.compareMonthly}
                                            </span>
                                        )}
                                </div>

                                <ul className="flex flex-col gap-2.5 flex-grow">
                                    {tier.features.map((f) => {
                                        const label = typeof f === "string" ? f : f.label;
                                        const note = typeof f === "string" ? undefined : f.note;
                                        return (
                                            <li key={label} className="flex items-start gap-3">
                                                <Check
                                                    className={cn(
                                                        "mt-0.5 h-4 w-4 flex-shrink-0",
                                                        tier.highlight ? HIGHLIGHT_STYLE.check : "text-muted-foreground"
                                                    )}
                                                    strokeWidth={2.4}
                                                />
                                                <span className={cn("text-sm leading-relaxed", tier.highlight ? HIGHLIGHT_STYLE.feature : "text-foreground/85")}>
                                                    {label}
                                                    {note && (
                                                        <span className={cn("mt-0.5 block text-xs leading-relaxed", tier.highlight ? HIGHLIGHT_STYLE.note : "text-muted-foreground")}>
                                                            {note}
                                                        </span>
                                                    )}
                                                </span>
                                            </li>
                                        );
                                    })}
                                </ul>

                                <DownloadButton
                                    placement={tier.placement}
                                    className={cn(
                                        "relative w-full rounded-full gap-2",
                                        // Standard (dark) cards: filled primary CTA with the hover/blur treatment.
                                        !tier.highlight &&
                                            "hover:bg-muted hover:text-foreground hover:border-border hover:backdrop-blur-md dark:hover:bg-input/30 dark:hover:text-foreground dark:hover:border-input",
                                        // Highlighted (Managed) card: a solid white CTA (see
                                        // HIGHLIGHT_STYLE.button) so it still pops on the dark card.
                                        tier.highlight && HIGHLIGHT_STYLE.button
                                    )}
                                    size="lg"
                                    variant={tier.cta.variant === "primary" ? "default" : "outline"}
                                >
                                    {tier.highlight ? (
                                        // Highlighted card: animated border tinted from the
                                        // section gradient (blue → teal → purple), per variant.
                                        <AnimatedBorder className={HIGHLIGHT_STYLE.animatedBorder} />
                                    ) : (
                                        <AnimatedBorder />
                                    )}
                                    <AppleIcon className="h-4 w-4" />
                                    {tier.cta.label}
                                </DownloadButton>
                            </Card>
                        </motion.div>
                    );
                })}
            </div>

            {/* Honest privacy distinction — a genuine selling point, not buried.
                Bumped to foreground/75 so it clears AA contrast over the gradient surface. */}
            <p className="relative z-10 mt-8 mx-auto max-w-2xl text-center text-sm text-foreground/75">
                Managed sends your recording to Zerro&apos;s server to generate the result.
                Bring-your-own-key stays fully on your Mac — recordings never leave your machine.
            </p>

            <p className="relative z-10 mt-4 text-center text-sm text-foreground/60">
                Prices listed in USD. The one-time BYOK purchase includes 1 year of updates;
                your installed version keeps working after that.
            </p>
        </motion.section>
    );
};

export default Pricing;
