import { randomUUID } from "node:crypto";
import { UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, MAIN_TABLE } from "./ddb.js";

export const newId = (): string => randomUUID();

export const now = (): number => Math.floor(Date.now() / 1000);

/**
 * Genera un folio de ticket atomico: TKT-<year>-<NNNN>.
 * Usa un item COUNTER#TICKET#<year> con UpdateItem ADD, garantizando
 * unicidad incluso bajo creaciones concurrentes.
 */
export async function nextTicketNumber(): Promise<string> {
  const year = new Date().getUTCFullYear();
  const res = await ddb.send(
    new UpdateCommand({
      TableName: MAIN_TABLE,
      Key: { PK: `COUNTER#TICKET#${year}`, SK: "COUNTER" },
      UpdateExpression: "ADD lastNumber :one SET entityType = :t",
      ExpressionAttributeValues: { ":one": 1, ":t": "COUNTER" },
      ReturnValues: "UPDATED_NEW",
    })
  );
  const n = Number(res.Attributes?.lastNumber ?? 1);
  return `TKT-${year}-${String(n).padStart(4, "0")}`;
}
