import type { Metadata } from "next";

// The auth page is a sign-in form with no content worth indexing. It's also
// disallowed in robots.ts; this keeps it out of search results belt-and-braces.
export const metadata: Metadata = {
  title: "Sign in",
  robots: { index: false, follow: false },
};

export default function AuthLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
