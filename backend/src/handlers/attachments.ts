import type {
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import { GetCommand, PutCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, MAIN_TABLE } from "../lib/ddb.js";
import { getAuth } from "../lib/auth.js";
import { newId, now } from "../lib/ids.js";
import {
  ALLOWED_MIME,
  MAX_UPLOAD_BYTES,
  ATTACHMENTS_BUCKET,
  presignPut,
  presignGet,
} from "../lib/s3.js";
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

  try {
    if (event.routeKey === "POST /attachments/presign") {
      return await presignUpload(event, auth);
    }
    if (event.routeKey === "GET /attachments/download") {
      return await presignDownload(event);
    }
    return notFound("Route not handled");
  } catch (err) {
    console.error("attachments handler error", err);
    return serverError();
  }
};

async function presignUpload(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
  auth: ReturnType<typeof getAuth>
) {
  if (!auth) return unauthorized();
  const body = JSON.parse(event.body ?? "{}");
  const { ticketId, commentId, fileName, mimeType, size } = body;

  if (!ticketId || !fileName || !mimeType) {
    return badRequest("ticketId, fileName y mimeType son obligatorios");
  }
  if (!ALLOWED_MIME.has(mimeType)) {
    return badRequest(`Tipo de archivo no permitido: ${mimeType}`);
  }
  if (size && Number(size) > MAX_UPLOAD_BYTES) {
    return badRequest(`El archivo supera el maximo de ${MAX_UPLOAD_BYTES} bytes`);
  }

  // Verifica que el ticket exista.
  const ticket = await ddb.send(
    new GetCommand({
      TableName: MAIN_TABLE,
      Key: { PK: `TICKET#${ticketId}`, SK: `METADATA#${ticketId}` },
    })
  );
  if (!ticket.Item) return notFound("Ticket no existe");

  const attachmentId = newId();
  const ts = now();
  const safeName = String(fileName).replace(/[^\w.\-]/g, "_");
  const parentType = commentId ? "COMMENT" : "TICKET";
  const key = commentId
    ? `attachments/${ticketId}/comments/${commentId}/${attachmentId}/${safeName}`
    : `attachments/${ticketId}/ticket/${attachmentId}/${safeName}`;

  const uploadUrl = await presignPut(key, mimeType);

  await ddb.send(
    new PutCommand({
      TableName: MAIN_TABLE,
      Item: {
        PK: `TICKET#${ticketId}`,
        SK: `ATTACHMENT#${attachmentId}`,
        entityType: "ATTACHMENT",
        parentType,
        commentId: commentId ?? null,
        ticketId,
        attachmentId,
        fileName: safeName,
        s3Key: key,
        s3Bucket: ATTACHMENTS_BUCKET,
        mimeType,
        size: size ?? null,
        status: "PENDING",
        uploadedBy: auth.sub,
        uploadedByName: auth.email,
        uploadedAt: ts,
      },
    })
  );

  // Incrementa el contador de adjuntos del ticket.
  await ddb.send(
    new UpdateCommand({
      TableName: MAIN_TABLE,
      Key: { PK: `TICKET#${ticketId}`, SK: `METADATA#${ticketId}` },
      UpdateExpression: "ADD attachmentCount :one",
      ExpressionAttributeValues: { ":one": 1 },
      ConditionExpression: "attribute_exists(PK)",
    })
  );

  return created({ attachmentId, key, uploadUrl, expiresIn: 300 });
}

async function presignDownload(
  event: APIGatewayProxyEventV2WithJWTAuthorizer
) {
  const ticketId = event.queryStringParameters?.ticketId;
  const attachmentId = event.queryStringParameters?.attachmentId;
  if (!ticketId || !attachmentId) {
    return badRequest("ticketId y attachmentId requeridos");
  }

  const res = await ddb.send(
    new GetCommand({
      TableName: MAIN_TABLE,
      Key: { PK: `TICKET#${ticketId}`, SK: `ATTACHMENT#${attachmentId}` },
    })
  );
  if (!res.Item) return notFound("Adjunto no existe");

  const downloadUrl = await presignGet(res.Item.s3Key as string);
  return ok({ downloadUrl, fileName: res.Item.fileName, expiresIn: 300 });
}
