import type {
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import { PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, MAIN_TABLE } from "../lib/ddb.js";
import { getAuth, hasRole } from "../lib/auth.js";
import { newId, now } from "../lib/ids.js";
import {
  ok,
  created,
  badRequest,
  unauthorized,
  forbidden,
  notFound,
  serverError,
} from "../lib/response.js";

export const handler = async (
  event: APIGatewayProxyEventV2WithJWTAuthorizer
): Promise<APIGatewayProxyResultV2> => {
  const auth = getAuth(event);
  if (!auth) return unauthorized();

  try {
    if (event.routeKey === "GET /areas") {
      // Lista de areas via GSI overload no necesaria: query por tipo con PK marker.
      const res = await ddb.send(
        new QueryCommand({
          TableName: MAIN_TABLE,
          KeyConditionExpression: "PK = :pk",
          ExpressionAttributeValues: { ":pk": "AREAS" },
        })
      );
      return ok({ items: res.Items ?? [] });
    }

    if (event.routeKey === "POST /areas") {
      if (!hasRole(auth, "ADMIN")) return forbidden();
      const body = JSON.parse(event.body ?? "{}");
      if (!body.name) return badRequest("name requerido");

      const areaId = body.areaId ?? newId();
      const ts = now();
      const item = {
        // Item de perfil del area (lookup directo).
        PK: `AREA#${areaId}`,
        SK: `PROFILE#${areaId}`,
        entityType: "AREA",
        areaId,
        name: body.name,
        description: body.description ?? "",
        managerId: body.managerId ?? null,
        isActive: true,
        createdAt: ts,
        updatedAt: ts,
      };
      await ddb.send(new PutCommand({ TableName: MAIN_TABLE, Item: item }));

      // Item espejo en la particion "AREAS" para listar todas las areas.
      await ddb.send(
        new PutCommand({
          TableName: MAIN_TABLE,
          Item: { ...item, PK: "AREAS", SK: `AREA#${areaId}` },
        })
      );

      return created(item);
    }

    return notFound("Route not handled");
  } catch (err) {
    console.error("areas handler error", err);
    return serverError();
  }
};
