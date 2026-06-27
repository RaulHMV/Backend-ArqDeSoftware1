import type {
  APIGatewayProxyWebsocketEventV2,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import { UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, WS_TABLE } from "../lib/ddb.js";
import { now } from "../lib/ids.js";
import { postToConnection } from "../lib/ws.js";

/**
 * Maneja mensajes entrantes por la ruta `sendMessage` (canal de heartbeat).
 * Refresca el TTL de la conexion y responde `pong`. El endpoint de gestion se
 * construye desde el contexto del evento, sin variable de entorno.
 */
export const handler = async (
  event: APIGatewayProxyWebsocketEventV2
): Promise<APIGatewayProxyResultV2> => {
  const connectionId = event.requestContext.connectionId;
  const endpoint = `https://${event.requestContext.domainName}/${event.requestContext.stage}`;

  await ddb.send(
    new UpdateCommand({
      TableName: WS_TABLE,
      Key: { connectionId },
      UpdateExpression: "SET lastHeartbeat = :ts, expirationTime = :exp",
      ExpressionAttributeValues: {
        ":ts": now(),
        ":exp": now() + 2 * 60 * 60,
      },
    })
  );
  await postToConnection(endpoint, connectionId, { type: "pong", ts: now() });

  return { statusCode: 200, body: "ok" };
};
