import type { Metadata } from "next";
import { Inter } from "next/font/google";
import Script from "next/script";
import { Analytics } from "@vercel/analytics/next";
import {
  OrganizationJsonLd,
  WebSiteJsonLd,
} from "@/components/structured-data";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
  weight: ["300", "400", "500", "600", "700"],
});

const sansFont = "var(--font-inter), ui-sans-serif, system-ui, sans-serif";

export const metadata: Metadata = {
  title: {
    default: "Zerro — Give your agent eyes and ears",
    template: "%s — Zerro",
  },
  description:
    "Record your screen, dictate what you want, and Zerro hands you exactly what you need — an agent prompt, a message, a snippet, a document, or a clear answer, ready to paste. Record it. Paste it. Zerro in between.",
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
    title: "Zerro — Give your agent eyes and ears",
    description:
      "Record your screen, dictate what you want, and Zerro hands you exactly what you need — a prompt, a message, a snippet, a document, or a clear answer. Record it. Paste it. Zerro in between.",
    url: "https://getzerro.app",
    siteName: "Zerro",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Zerro — Give your agent eyes and ears",
    description:
      "Record your screen, dictate what you want, and get exactly what you need — a prompt, a message, a snippet, a document, or a clear answer.",
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
        <div
          className={`${inter.variable} min-h-screen w-full bg-background font-light text-foreground`}
          style={{ fontFamily: sansFont }}
        >
          {children}
        </div>
        <Analytics />
        {/* LemonSqueezy affiliate tracking. The config must be set before
            affiliate.js loads, so the inline config runs beforeInteractive. */}
        <Script id="lemonsqueezy-affiliate-config" strategy="beforeInteractive">
          {`window.lemonSqueezyAffiliateConfig = { store: "zerro" };`}
        </Script>
        <Script src="https://lmsqueezy.com/affiliate.js" strategy="afterInteractive" />
      </body>
    </html>
  );
}
