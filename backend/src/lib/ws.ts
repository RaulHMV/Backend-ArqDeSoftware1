import {
  ApiGatewayManagementApiClient,
  PostToConnectionCommand,
} from "@aws-sdk/client-apigatewaymanagementapi";
import { DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, WS_TABLE } from "./ddb.js";

const region = process.env.APP_REGION ?? process.env.AWS_REGION;

function clientFor(endpoint: string): ApiGatewayManagementApiClient {
  return new ApiGatewayManagementApiClient({ region, endpoint });
}

/**
 * Envia un payload a una conexion WebSocket. Si la conexion esta muerta
 * (410 Gone), borra el item de WSConnections de inmediato (no espera al TTL).
 */
export async function postToConnection(
  endpoint: string,
  connectionId: string,
  payload: unknown
): Promise<void> {
  try {
    await clientFor(endpoint).send(
      new PostToConnectionCommand({
        ConnectionId: connectionId,
        Data: Buffer.from(JSON.stringify(payload)),
      })
    );
  } catch (err: unknown) {
    const statusCode =
      (err as { $metadata?: { httpStatusCode?: number } })?.$metadata
        ?.httpStatusCode ?? 0;
    if (statusCode === 410) {
      await ddb.send(
        new DeleteCommand({ TableName: WS_TABLE, Key: { connectionId } })
      );
    } else {
      throw err;
    }
  }
}

/** Difunde a varias conexiones, tolerando fallos individuales. */
export async function broadcast(
  endpoint: string,
  connectionIds: string[],
  payload: unknown
): Promise<void> {
  await Promise.allSettled(
    connectionIds.map((id) => postToConnection(endpoint, id, payload))
  );
}
