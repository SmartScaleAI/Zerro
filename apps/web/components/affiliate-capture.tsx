"use client";

import { useEffect } from "react";
import { FUNCTIONS_BASE_URL } from "@/lib/site-config";

// Records the affiliate referral on landing.
//
// When a visitor arrives via an affiliate link (getzerro.app/?aff=CODE), we
// send the code to the `affiliate` Edge Function, which stores it keyed to the
// visitor's public IP. Purchasing happens only inside the Mac app — a different
// browser/app context — so a browser cookie (LemonSqueezy's affiliate.js) can't
// carry the referral to checkout. The app instead matches on that IP at
// checkout time and tags the LemonSqueezy checkout with `aff_ref`.
//
// Mounted once in the root layout, so it captures `?aff` on whichever page the
// affiliate link points at. Fire-and-forget: a failed beacon just means no
// attribution, never a broken page.
export function AffiliateCapture() {
  useEffect(() => {
    const aff = new URLSearchParams(window.location.search).get("aff");
    if (!aff) return;

    fetch(`${FUNCTIONS_BASE_URL}/affiliate`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ aff }),
      keepalive: true,
    }).catch(() => {
      /* no-op: attribution is best-effort */
    });
  }, []);

  return null;
}
