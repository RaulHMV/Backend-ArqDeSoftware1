import type {
  APIGatewayProxyWebsocketEventV2,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import { PutCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, WS_TABLE } from "../lib/ddb.js";
import { now } from "../lib/ids.js";

const TTL_SECONDS = 2 * 60 * 60; // 2 horas

export const handler = async (
  event: APIGatewayProxyWebsocketEventV2
): Promise<APIGatewayProxyResultV2> => {
  const connectionId = event.requestContext.connectionId;
  // El contexto viene del Lambda Authorizer del $connect.
  const ctx = (event.requestContext as unknown as {
    authorizer?: Record<string, string>;
  }).authorizer ?? {};

  const ts = now();
  await ddb.send(
    new PutCommand({
      TableName: WS_TABLE,
      Item: {
        connectionId,
        userId: ctx.userId ?? "unknown",
        userEmail: ctx.email ?? "",
        areaId: ctx.areaId || "UNASSIGNED",
        role: ctx.groups ?? "",
        connectedAt: ts,
        lastHeartbeat: ts,
        expirationTime: ts + TTL_SECONDS,
      },
    })
  );

  return { statusCode: 200, body: "Connected" };
};
