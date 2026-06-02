// Small HTTP helpers shared by the Edge Functions. The Zerro Mac app is a
// native client (no browser CORS preflight needed), but permissive CORS keeps
// the functions curl- and browser-testable during development.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-signature, x-event-name",
};

/** JSON response with CORS + content-type set. */
export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/** Plain-text response (used for the bare-200 webhook acks). */
export function text(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: { ...corsHeaders, "Content-Type": "text/plain" },
  });
}

/** Standard CORS preflight handler. Returns a Response for OPTIONS, else null. */
export function handlePreflight(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  return null;
}
