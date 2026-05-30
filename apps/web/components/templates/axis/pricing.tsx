"use client";

import { Button } from "@/components/ui/button";
import { AnimatedBorder } from "@/components/ui/animated-border";
import { BorderTrail } from "@/components/ui/border-trail";
import { Card } from "@/components/ui/card";
import { GradientField } from "@/components/ui/gradient-field";
import { DOWNLOAD_URL } from "@/lib/site-config";
import { cn } from "@/lib/utils";
import { Check, Bell } from "lucide-react";
import { AppleIcon } from "@/components/ui/apple-icon";
import { motion } from "motion/react";

type Tier = {
    name: string;
    blurb: string;
    price: string;
    cadence: string;
    altPrice?: string;
    savings?: string;
    badge: string;
    badgeStyle: "primary" | "muted";
    features: string[];
    cta: { label: string; icon: React.ComponentType<{ className?: string }>; variant: "primary" | "outline" };
    available: boolean;
    highlight?: boolean;
};

const tiers: Tier[] = [
    {
        name: "BYOK",
        blurb: "Pay once. Bring your own keys.",
        price: "$39",
        cadence: "one-time",
        badge: "Available now",
        badgeStyle: "primary",
        features: [
            "7-day free trial — no card required",
            "All features and future updates",
            "Bring your own OpenAI + Gemini keys",
            "Keys stored in your macOS Keychain",
            "No subscription, no account required",
            "No servers handling your data",
        ],
        cta: { label: "Download for macOS", icon: AppleIcon, variant: "primary" },
        available: true,
    },
    {
        name: "Managed",
        blurb: "We handle the tokens — no keys, no setup.",
        price: "$12",
        cadence: "per month",
        altPrice: "or $96/yr",
        savings: "Save 33%",
        badge: "Coming soon",
        badgeStyle: "muted",
        features: [
            "7-day free trial",
            "No API keys required",
            "Monthly recording credits included",
            "We manage all token usage",
            "Priority support",
            "Cancel anytime",
        ],
        cta: { label: "Notify me", icon: Bell, variant: "outline" },
        available: false,
        highlight: true,
    },
];

const Pricing = () => {
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

            <div className="relative z-10 mb-12 lg:mb-16 flex flex-col items-center gap-3 text-center">
                <p className="text-xs font-medium uppercase tracking-[0.18em] text-primary">
                    Pricing
                </p>
                <h2 className="text-3xl font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl max-w-2xl leading-tight">
                    Pay once, or let us handle it.
                </h2>
                <p className="max-w-xl text-base text-muted-foreground">
                    BYOK is available at launch. Managed tiers open up shortly after — drop your email and we&apos;ll let you know.
                </p>
            </div>

            <div className="relative z-10 grid grid-cols-1 items-center gap-4 lg:grid-cols-[1fr_1.15fr] lg:gap-0 max-w-5xl mx-auto">
                {tiers.map((tier, i) => {
                    const Icon = tier.cta.icon;
                    const isLeft = i === 0;
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
                                    : "z-0"
                            )}
                        >
                            <Card
                                className={cn(
                                    "relative flex flex-col gap-6",
                                    tier.highlight
                                        ? "h-full p-8 lg:p-10 border-white/10 bg-white text-neutral-900 shadow-[0_40px_100px_-20px_rgba(0,0,0,0.55)]"
                                        : "p-7 border-border bg-card/60",
                                    // Flatten the inner edge so the two cards butt together on desktop.
                                    !tier.highlight && (isLeft ? "lg:rounded-r-none lg:pr-10" : "lg:rounded-l-none lg:pl-10")
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
                                            "shrink-0 rounded-full px-2.5 py-0.5 text-[10px] font-medium uppercase tracking-wider",
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
                                    <span className={cn("text-4xl lg:text-5xl font-medium tracking-tighter", tier.highlight ? "text-neutral-900" : "text-foreground")}>
                                        {tier.price}
                                    </span>
                                    <span className={cn("text-sm", tier.highlight ? "text-neutral-500" : "text-muted-foreground")}>{tier.cadence}</span>
                                    {tier.altPrice && (
                                        <span className={cn("text-sm", tier.highlight ? "text-neutral-500" : "text-muted-foreground")}>{tier.altPrice}</span>
                                    )}
                                    {tier.savings && (
                                        <span className="rounded-full bg-primary/10 px-2 py-0.5 text-[11px] font-medium text-primary">
                                            {tier.savings}
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
                                        // BYOK (dark card): filled primary CTA with the hover/blur treatment.
                                        tier.available &&
                                            "hover:bg-muted hover:text-foreground hover:border-border hover:backdrop-blur-md dark:hover:bg-input/30 dark:hover:text-foreground dark:hover:border-input",
                                        // Managed (white card): a dark outline button that reads on white.
                                        tier.highlight &&
                                            "border-neutral-300 bg-transparent text-neutral-500 hover:bg-transparent dark:border-neutral-300 dark:bg-transparent dark:text-neutral-500"
                                    )}
                                    size="lg"
                                    variant={tier.cta.variant === "primary" ? "default" : "outline"}
                                    disabled={!tier.available}
                                    {...(tier.available
                                        ? {
                                              nativeButton: false,
                                              render: <a href={DOWNLOAD_URL} download />,
                                          }
                                        : {})}
                                >
                                    {tier.available && <AnimatedBorder />}
                                    <Icon className="h-4 w-4" />
                                    {tier.cta.label}
                                </Button>
                            </Card>
                        </motion.div>
                    );
                })}
            </div>

            <p className="relative z-10 mt-8 text-center text-xs text-muted-foreground">
                Prices listed in USD. One-time purchase includes all v1 features and updates.
            </p>
        </motion.section>
    );
};

export default Pricing;
