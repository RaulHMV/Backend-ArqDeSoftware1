import type { APIGatewayProxyResultV2 } from "aws-lambda";

const CORS = {
  "content-type": "application/json",
  "access-control-allow-origin": "*",
};

export function json(
  statusCode: number,
  body: unknown
): APIGatewayProxyResultV2 {
  return { statusCode, headers: CORS, body: JSON.stringify(body) };
}

export const ok = (body: unknown) => json(200, body);
export const created = (body: unknown) => json(201, body);
export const badRequest = (msg: string) => json(400, { error: msg });
export const unauthorized = (msg = "Unauthorized") => json(401, { error: msg });
export const forbidden = (msg = "Forbidden") => json(403, { error: msg });
export const notFound = (msg = "Not found") => json(404, { error: msg });
export const serverError = (msg = "Internal error") => json(500, { error: msg });
