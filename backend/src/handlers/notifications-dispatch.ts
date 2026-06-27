import type { DynamoDBStreamEvent } from "aws-lambda";
import { unmarshall } from "@aws-sdk/util-dynamodb";
import type { AttributeValue } from "@aws-sdk/client-dynamodb";
import { GetCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, MAIN_TABLE, WS_TABLE } from "../lib/ddb.js";
import { broadcast } from "../lib/ws.js";
import { getParam } from "../lib/ssm.js";

const WS_ENDPOINT_PARAM = process.env.WS_ENDPOINT_PARAM as string;

async function connectionsByArea(areaId: string): Promise<string[]> {
  if (!areaId) return [];
  const res = await ddb.send(
    new QueryCommand({
      TableName: WS_TABLE,
      IndexName: "GSIByArea",
      KeyConditionExpression: "areaId = :a",
      ExpressionAttributeValues: { ":a": areaId },
    })
  );
  return (res.Items ?? []).map((i) => i.connectionId as string);
}

async function connectionsByUser(userId: string | null): Promise<string[]> {
  if (!userId) return [];
  const res = await ddb.send(
    new QueryCommand({
      TableName: WS_TABLE,
      IndexName: "GSIByUser",
      KeyConditionExpression: "userId = :u",
      ExpressionAttributeValues: { ":u": userId },
    })
  );
  return (res.Items ?? []).map((i) => i.connectionId as string);
}

/**
 * Resuelve destinatarios con Query sobre los GSI de WSConnections (nunca Scan)
 * y difunde el evento. El borrado de conexiones muertas (410) lo hace ws.ts.
 */
export const handler = async (event: DynamoDBStreamEvent): Promise<void> => {
  const endpoint = await getParam(WS_ENDPOINT_PARAM);
  if (!endpoint) {
    console.warn("WS endpoint no configurado todavia");
    return;
  }

  for (const record of event.Records) {
    if (record.eventName !== "INSERT" && record.eventName !== "MODIFY") continue;
    const image = record.dynamodb?.NewImage;
    if (!image) continue;

    const item = unmarshall(
      image as Record<string, AttributeValue>
    ) as Record<string, unknown>;
    const entityType = item.entityType as string;

    let connections: string[] = [];
    let payload: Record<string, unknown> | null = null;

    if (entityType === "TICKET") {
      const areaId = String(item.areaId ?? "");
      connections = await connectionsByArea(areaId);
      payload = {
        type: "TICKET",
        event: record.eventName,
        ticketId: item.ticketId,
        number: item.number,
        title: item.title,
        state: item.state,
        priority: item.priority,
        areaId,
      };
    } else if (entityType === "COMMENT") {
      const ticketId = String(item.ticketId ?? "");
      const ticket = await ddb.send(
        new GetCommand({
          TableName: MAIN_TABLE,
          Key: { PK: `TICKET#${ticketId}`, SK: `METADATA#${ticketId}` },
        })
      );
      const t = ticket.Item ?? {};
      const byUser = await Promise.all([
        connectionsByUser((t.requesterId as string) ?? null),
        connectionsByUser((t.assignedToId as string) ?? null),
      ]);
      const byArea = await connectionsByArea(String(t.areaId ?? ""));
      connections = [...byUser.flat(), ...byArea];
      payload = {
        type: "COMMENT",
        event: record.eventName,
        ticketId,
        commentId: item.commentId,
        authorName: item.authorName,
        preview: String(item.content ?? "").slice(0, 140),
      };
    }

    if (payload && connections.length > 0) {
      const unique = [...new Set(connections)];
      await broadcast(endpoint, unique, payload);
    }
  }
};
