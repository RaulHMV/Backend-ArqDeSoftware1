import type {
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import { PutCommand, QueryCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, MAIN_TABLE } from "../lib/ddb.js";
import { getAuth } from "../lib/auth.js";
import { newId, now } from "../lib/ids.js";
import {
  ok,
  created,
  badRequest,
  unauthorized,
  notFound,
  serverError,
} from "../lib/response.js";

export const handler = async (
  event: APIGatewayProxyEventV2WithJWTAuthorizer
): Promise<APIGatewayProxyResultV2> => {
  const auth = getAuth(event);
  if (!auth) return unauthorized();

  const ticketId = event.pathParameters?.id;
  if (!ticketId) return badRequest("ticketId requerido");

  try {
    if (event.routeKey === "GET /tickets/{id}/comments") {
      const res = await ddb.send(
        new QueryCommand({
          TableName: MAIN_TABLE,
          KeyConditionExpression: "PK = :pk AND begins_with(SK, :sk)",
          ExpressionAttributeValues: {
            ":pk": `TICKET#${ticketId}`,
            ":sk": "COMMENT#",
          },
          ScanIndexForward: true,
        })
      );
      return ok({ items: res.Items ?? [] });
    }

    if (event.routeKey === "POST /tickets/{id}/comments") {
      const body = JSON.parse(event.body ?? "{}");
      if (!body.content) return badRequest("content requerido");

      const commentId = newId();
      const ts = now();
      const item = {
        PK: `TICKET#${ticketId}`,
        SK: `COMMENT#${commentId}#${ts}`,
        entityType: "COMMENT",
        ticketId,
        commentId,
        authorId: auth.sub,
        authorName: auth.email,
        authorRole: auth.role,
        content: body.content,
        type: body.type === "INTERNAL" ? "INTERNAL" : "PUBLIC",
        isVisible: true,
        mentions: body.mentions ?? [],
        createdAt: ts,
        updatedAt: ts,
      };

      await ddb.send(new PutCommand({ TableName: MAIN_TABLE, Item: item }));

      // Incrementa el contador del ticket de forma atomica.
      await ddb.send(
        new UpdateCommand({
          TableName: MAIN_TABLE,
          Key: { PK: `TICKET#${ticketId}`, SK: `METADATA#${ticketId}` },
          UpdateExpression: "ADD commentCount :one SET updatedAt = :ts",
          ExpressionAttributeValues: { ":one": 1, ":ts": ts },
          ConditionExpression: "attribute_exists(PK)",
        })
      );

      return created(item);
    }

    return notFound("Route not handled");
  } catch (err) {
    console.error("comments handler error", err);
    return serverError();
  }
};
