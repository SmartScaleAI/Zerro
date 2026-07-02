"use client";

import { useEffect, useRef } from "react";
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

const Page = () => {
    // The license-bearing deep link is held in a ref (memory) and NEVER written
    // to the DOM. Critically, the fallback <a> keeps a key-free href and hands
    // off via onClick from this ref — if the full link were the anchor's href,
    // PostHog autocapture would lift the license key off `attr__href` on click.
    const deepLinkRef = useRef(APP_SCHEME);

    useEffect(() => {
        // K-01: capture the LemonSqueezy query string (license_key / order_id /
        // product …) into memory ONCE, before anything scrubs it. The deep link
        // is built from this snapshot so the desktop app still receives the key.
        // Reading `window.location.search` (not `useSearchParams`) keeps this a
        // simple client component with no Suspense/SSR bail-out.
        const search = window.location.search;
        const url = `${APP_SCHEME}${search}`;
        deepLinkRef.current = url;

        // Replace the https URL with a key-free one so the license key never
        // persists in the address bar / browser history and can't ride the
        // `Referer` on any later outbound subresource request from this page.
        // (Analytics is a separate concern: the manual `$pageview` reads
        // `useSearchParams`, which replaceState does NOT update, so the PostHog
        // `before_send` hook — not this line — is what keeps the key out of
        // analytics.) The in-memory `url` keeps the key for the hand-off below.
        if (search) {
            window.history.replaceState(null, "", window.location.pathname);
        }

        // Auto-attempt the hand-off. Assigning a custom scheme triggers the OS
        // handler without navigating this document, so the cleaned URL stays put.
        // If Zerro is installed, macOS opens it; if not, nothing visible happens
        // and the manual button below is the fallback. Either way the app
        // re-checks entitlement when it next becomes active, so the purchase is
        // never lost.
        window.location.href = url;
    }, []);

    // Manual fallback. The anchor's href is the key-free scheme (autocapture-safe);
    // the real navigation uses the in-memory deep link so the app still gets the key.
    const handleOpen = (e: React.MouseEvent<HTMLAnchorElement>) => {
        e.preventDefault();
        window.location.href = deepLinkRef.current;
    };

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
                        href={APP_SCHEME}
                        onClick={handleOpen}
                        className={cn(buttonVariants(), "w-full rounded-full")}
                    >
                        Open Zerro
                    </a>

                    <p className="text-sm text-muted-foreground font-light">
                        If Zerro doesn&apos;t open automatically, click the button
                        above, or just switch back to the app and it&apos;ll
                        update on its own. You can close this tab.
                    </p>
                </CardContent>
            </Card>
        </div>
    );
};

export default Page;
