"use client";

import { useEffect, useState } from "react";
import Image from "next/image";
import Link from "next/link";
import { buttonVariants } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { GradientField } from "@/components/ui/gradient-field";
import { cn } from "@/lib/utils";

// LemonSqueezy's confirmation-modal "Button link" field forces an `https://`
// prefix and rejects custom URL schemes, so it can't point at `zerro://`
// directly. Instead it points here — https://getzerro.app/checkout-complete —
// and this page forwards the buyer straight into the desktop app via the
// `zerro://checkout-complete` deep link, carrying every query param through
// (e.g. product, and LemonSqueezy link variables like [license_key]/[order_id]).
const APP_SCHEME = "zerro://checkout-complete";

const buildDeepLink = (): string => {
    // Read the live query string so all LemonSqueezy params pass through
    // verbatim. Reading from `window.location` (not `useSearchParams`) keeps the
    // page a simple client component with no Suspense/SSR bail-out.
    const search = typeof window !== "undefined" ? window.location.search : "";
    return `${APP_SCHEME}${search}`;
};

const Page = () => {
    const [deepLink, setDeepLink] = useState(APP_SCHEME);

    useEffect(() => {
        const url = buildDeepLink();
        setDeepLink(url);
        // Auto-attempt the hand-off. If Zerro is installed, macOS opens it; if
        // not, nothing visible happens and the manual button below is the
        // fallback. Either way the app also re-checks entitlement when it next
        // becomes active, so the purchase is never lost.
        window.location.href = url;
    }, []);

    return (
        <div className="relative flex min-h-screen h-full w-full flex-col items-center justify-center gap-6 p-4">
            <GradientField solid edgeFade="none" className="inset-0 z-0" />
            <Link href="/" className="relative z-10 flex items-center">
                <Image
                    src="/logo/zerro-mark.svg"
                    alt="Zerro"
                    width={36}
                    height={36}
                    className="-ml-1 h-9 w-9 text-foreground dark:invert"
                    priority
                />
                <span className="text-xl font-medium tracking-tight text-foreground">
                    Zerro
                </span>
            </Link>

            <Card className="relative z-10 w-full max-w-105 border-0 bg-background dark:bg-background/80 shadow-xl backdrop-blur-sm rounded-4xl">
                <CardContent className="px-8 pt-8 pb-8 max-w-sm mx-auto space-y-6 text-center">
                    <div className="flex flex-col items-center">
                        <h1 className="text-2xl font-medium tracking-tight text-foreground">
                            Payment successful
                        </h1>
                        <p className="mt-2 text-sm text-muted-foreground font-light">
                            Opening Zerro to finish setting up your plan&hellip;
                        </p>
                    </div>

                    <a
                        href={deepLink}
                        className={cn(buttonVariants(), "w-full rounded-full")}
                    >
                        Open Zerro
                    </a>

                    <p className="text-sm text-muted-foreground font-light">
                        If Zerro doesn&apos;t open automatically, click the button
                        above &mdash; or just switch back to the app and it&apos;ll
                        update on its own. You can close this tab.
                    </p>
                </CardContent>
            </Card>
        </div>
    );
};

export default Page;
