import type { Metadata } from "next";
import { Inter } from "next/font/google";
import { AffiliateCapture } from "@/components/affiliate-capture";
import {
  OrganizationJsonLd,
  WebSiteJsonLd,
} from "@/components/structured-data";
import { PostHogProvider } from "./providers";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
  weight: ["300", "400", "500", "600", "700"],
});

const sansFont = "var(--font-inter), ui-sans-serif, system-ui, sans-serif";

export const metadata: Metadata = {
  title: {
    default: "Zerro: Stop typing out what's already on your screen",
    template: "%s | Zerro",
  },
  description:
    "Record your screen, dictate what you want, and Zerro hands you exactly what you need: an agent prompt, a message, a snippet, a document, or a clear answer, ready to paste. Record it. Paste it. Zerro in between.",
  applicationName: "Zerro",
  metadataBase: new URL("https://getzerro.app"),
  alternates: {
    canonical: "/",
  },
  keywords: [
    "screen recording to prompt",
    "AI prompt generator",
    "voice to AI prompt",
    "dictate to AI",
    "screen to text",
    "macOS menu bar app",
    "voice dictation for coding",
    "AI coding agent",
  ],
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
      "max-video-preview": -1,
    },
  },
  // Paste the Google Search Console verification token here once available:
  // verification: { google: "your-token" },
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "any" },
      { url: "/favicon-16x16.png", type: "image/png", sizes: "16x16" },
      { url: "/favicon-32x32.png", type: "image/png", sizes: "32x32" },
    ],
    apple: [{ url: "/apple-touch-icon.png", sizes: "180x180" }],
  },
  openGraph: {
    title: "Zerro: Stop typing out what's already on your screen",
    description:
      "Record your screen, explain what you want, get the answer in seconds.",
    url: "https://getzerro.app",
    siteName: "Zerro",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Zerro: Stop typing out what's already on your screen",
    description:
      "Record your screen, explain what you want, get the answer in seconds.",
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark" suppressHydrationWarning>
      <body
        className={`${inter.variable} bg-background font-light w-full text-foreground antialiased`}
        style={{ fontFamily: sansFont }}
      >
        <OrganizationJsonLd />
        <WebSiteJsonLd />
        <PostHogProvider>
          <div
            className={`${inter.variable} min-h-screen w-full bg-background font-light text-foreground`}
            style={{ fontFamily: sansFont }}
          >
            {children}
          </div>
        </PostHogProvider>
        {/* Affiliate attribution. Purchasing happens only in the Mac app, in a
            different browser context, so LemonSqueezy's browser affiliate.js
            can't carry the referral to checkout. Instead we record the `?aff`
            code server-side (keyed to the visitor's IP); the app matches it at
            checkout and tags `aff_ref`. See components/affiliate-capture.tsx. */}
        <AffiliateCapture />
      </body>
    </html>
  );
}
