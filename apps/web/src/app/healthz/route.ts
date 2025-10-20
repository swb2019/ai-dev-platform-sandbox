// Lightweight health check endpoint used by Kubernetes probes.
export function GET(): Response {
  return Response.json({ status: 'ok' });
}
