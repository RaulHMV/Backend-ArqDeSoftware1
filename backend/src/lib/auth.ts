import type { APIGatewayProxyEventV2WithJWTAuthorizer } from "aws-lambda";
import type { AuthContext, Role } from "../types/index.js";

const ROLE_ORDER: Role[] = ["REQUESTER", "AGENT", "MANAGER", "ADMIN"];

function rolesFromGroups(groups: string[]): Role {
  // El rol efectivo es el de mayor privilegio entre los grupos de Cognito.
  let role: Role = "REQUESTER";
  for (const g of groups) {
    const upper = g.toUpperCase() as Role;
    if (ROLE_ORDER.includes(upper) && ROLE_ORDER.indexOf(upper) > ROLE_ORDER.indexOf(role)) {
      role = upper;
    }
  }
  return role;
}

/** Extrae el contexto de auth desde los claims del JWT authorizer de la HTTP API. */
export function getAuth(
  event: APIGatewayProxyEventV2WithJWTAuthorizer
): AuthContext | null {
  const claims = event.requestContext.authorizer?.jwt?.claims;
  if (!claims) return null;

  const sub = String(claims.sub ?? "");
  if (!sub) return null;

  const rawGroups = claims["cognito:groups"];
  let groups: string[] = [];
  if (Array.isArray(rawGroups)) {
    groups = rawGroups.map(String);
  } else if (typeof rawGroups === "string") {
    // Cognito puede enviarlo como "[Admin Agent]" o "Admin,Agent".
    groups = rawGroups.replace(/^\[|\]$/g, "").split(/[\s,]+/).filter(Boolean);
  }

  return {
    sub,
    email: String(claims.email ?? ""),
    groups,
    role: rolesFromGroups(groups),
    areaId: claims["custom:areaId"] ? String(claims["custom:areaId"]) : null,
  };
}

export function hasRole(auth: AuthContext, ...allowed: Role[]): boolean {
  return allowed.includes(auth.role);
}
