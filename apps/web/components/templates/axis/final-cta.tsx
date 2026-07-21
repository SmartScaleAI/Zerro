"use client";

import { DownloadButton } from "@/components/download-button";
import { AnimatedBorder } from "@/components/ui/animated-border";
import { DotPattern } from "@/components/ui/dot-pattern";
import { cn } from "@/lib/utils";
import { AppleIcon } from "@/components/ui/apple-icon";
import { motion } from "motion/react";

const FinalCTA = () => {
    return (
        <motion.section
            className="relative mx-auto w-full max-w-7xl px-4"
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.15 }}
            transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
        >
            <div
                className="relative overflow-hidden rounded-3xl border border-border px-6 py-16 lg:px-12 lg:py-24 bg-gradient-to-br from-[oklch(0.99_0_0)] via-[oklch(0.975_0_0)] to-[oklch(0.96_0_0)] dark:from-[oklch(0.20_0_0)] dark:via-[oklch(0.14_0_0)] dark:to-[oklch(0.09_0_0)]"
            >
                {/* Dot texture — base-most layer, faded toward the card edges */}
                <DotPattern
                    width={20}
                    height={20}
                    dotSize={1}
                    className={cn("text-foreground/40 dark:text-foreground/20")}
                    style={{
                        maskImage:
                            "radial-gradient(80% 80% at 50% 45%, black, transparent)",
                        WebkitMaskImage:
                            "radial-gradient(80% 80% at 50% 45%, black, transparent)",
                    }}
                />

                {/* Ambient glow */}
                <div
                    aria-hidden="true"
                    className="absolute inset-0 flex items-center justify-center pointer-events-none"
                >
                    <div
                        className="h-[80%] w-[60%] rounded-full opacity-60 blur-[120px]"
                        style={{
                            background:
                                "radial-gradient(circle at center, rgba(170,185,200,0.55), rgba(170,185,200,0) 70%)",
                        }}
                    />
                </div>

                <div className="relative flex flex-col items-center text-center gap-8">
                    <h2 className="text-4xl md:text-5xl lg:text-6xl font-medium tracking-tighter text-foreground leading-[1.05] max-w-3xl">
                        Record it. Paste it.{" "}
                        <br />
                        <motion.span
                            className="bg-clip-text text-transparent bg-[length:200%_auto]"
                            style={{
                                backgroundImage:
                                    "linear-gradient(to right, rgb(135,160,215), rgb(115,190,165), rgb(180,140,215), rgb(125,190,150), rgb(135,160,215))",
                            }}
                            animate={{ backgroundPosition: ["200% center", "-200% center"] }}
                            transition={{
                                repeat: Number.POSITIVE_INFINITY,
                                duration: 9,
                                ease: "linear",
                            }}
                        >
                            Zerro in between.
                        </motion.span>
                    </h2>
                    <p className="max-w-xl text-base text-muted-foreground">
                        Stop describing what you want. Show it. Zerro turns the recording into exactly what you need: a prompt, a message, a snippet, a document, or a straight answer.
                    </p>
                    <div className="flex flex-col items-center gap-3">
                        <DownloadButton
                            placement="final_cta"
                            className="relative rounded-full gap-2 hover:bg-muted hover:text-foreground hover:border-border hover:backdrop-blur-md dark:hover:bg-input/30 dark:hover:text-foreground dark:hover:border-input"
                            size="lg"
                        >
                            <AnimatedBorder />
                            <AppleIcon className="h-4 w-4" />
                            Download for Mac
                        </DownloadButton>
                        <p className="text-sm text-muted-foreground">
                            {"Apple Silicon · Signed & notarized"}
                        </p>
                    </div>
                </div>
            </div>
        </motion.section>
    );
};

export default FinalCTA;
