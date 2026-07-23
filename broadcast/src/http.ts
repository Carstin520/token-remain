export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export function json(data: unknown, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  headers.set("content-type", "application/json; charset=utf-8");
  headers.set("x-content-type-options", "nosniff");
  return new Response(JSON.stringify(data), { ...init, headers });
}

export async function readJSON<T>(request: Request): Promise<T> {
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    throw new HttpError(415, "application/json is required");
  }
  try {
    return await request.json<T>();
  } catch {
    throw new HttpError(400, "invalid JSON");
  }
}

export function bearerToken(request: Request): string | null {
  const value = request.headers.get("authorization");
  if (!value?.startsWith("Bearer ")) return null;
  return value.slice("Bearer ".length).trim();
}

export function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  if (a.byteLength !== b.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < a.byteLength; index += 1) {
    difference |= a[index]! ^ b[index]!;
  }
  return difference === 0;
}

export function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return json({ detail: error.message }, { status: error.status });
  }
  console.error("Unhandled request failure", error instanceof Error ? error.message : "unknown");
  return json({ detail: "internal server error" }, { status: 500 });
}
