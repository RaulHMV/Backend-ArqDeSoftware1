import type {
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import {
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";
import { ddb, MAIN_TABLE } from "../lib/ddb.js";
import { getAuth, hasRole } from "../lib/auth.js";
import { newId, now, nextTicketNumber } from "../lib/ids.js";
import {
  ok,
  created,
  badRequest,
  unauthorized,
  forbidden,
  notFound,
  serverError,
} from "../lib/response.js";
import type { Priority, TicketState } from "../types/index.js";

const VALID_PRIORITY: Priority[] = ["LOW", "MEDIUM", "HIGH", "CRITICAL"];
const VALID_STATES: TicketState[] = [
  "NEW",
  "ASSIGNED",
  "IN_PROGRESS",
  "RESOLVED",
  "CLOSED",
];

export const handler = async (
  event: APIGatewayProxyEventV2WithJWTAuthorizer
): Promise<APIGatewayProxyResultV2> => {
  const auth = getAuth(event);
  if (!auth) return unauthorized();

  try {
    switch (event.routeKey) {
      case "POST /tickets":
        return await createTicket(event, auth);
      case "GET /tickets":
        return await listTickets(event, auth);
      case "GET /tickets/{id}":
        return await getTicket(event, auth);
      case "PUT /tickets/{id}":
        return await updateTicket(event, auth);
      default:
        return notFound("Route not handled");
    }
  } catch (err) {
    console.error("tickets handler error", err);
    return serverError();
  }
};

async function createTicket(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
  auth: ReturnType<typeof getAuth>
) {
  if (!auth) return unauthorized();
  const body = JSON.parse(event.body ?? "{}");
  const { title, description, category, priority, areaId } = body;

  if (!title || !description || !areaId) {
    return badRequest("title, description y areaId son obligatorios");
  }
  if (priority && !VALID_PRIORITY.includes(priority)) {
    return badRequest("priority invalida");
  }

  const ticketId = newId();
  const ts = now();
  const prio: Priority = priority ?? "MEDIUM";
  const state: TicketState = "NEW";
  const number = await nextTicketNumber();

  const item = {
    PK: `TICKET#${ticketId}`,
    SK: `METADATA#${ticketId}`,
    entityType: "TICKET",
    ticketId,
    number,
    title,
    description,
    category: category ?? "GENERAL",
    priority: prio,
    state,
    requesterId: auth.sub,
    requesterName: auth.email,
    requesterEmail: auth.email,
    areaId,
    assignedToId: null,
    assignedToName: null,
    createdAt: ts,
    updatedAt: ts,
    commentCount: 0,
    worklogCount: 0,
    attachmentCount: 0,
    // GSI1: area + estado
    GSI1PK: `AREA#${areaId}#${state}`,
    GSI1SK: `TICKET#${prio}#${ts}`,
    // GSI2: por requester
    GSI2PK: `REQUESTER#${auth.sub}`,
    GSI2SK: `TICKET#${ts}`,
    // GSI4: todos los tickets del area
    GSI4PK: `AREA#${areaId}`,
    GSI4SK: `TICKET#${state}#${prio}#${ts}`,
  };

  await ddb.send(new PutCommand({ TableName: MAIN_TABLE, Item: item }));
  return created(item);
}

async function getTicket(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
  auth: ReturnType<typeof getAuth>
) {
  if (!auth) return unauthorized();
  const id = event.pathParameters?.id;
  if (!id) return badRequest("id requerido");

  const res = await ddb.send(
    new GetCommand({
      TableName: MAIN_TABLE,
      Key: { PK: `TICKET#${id}`, SK: `METADATA#${id}` },
    })
  );
  if (!res.Item) return notFound("Ticket no existe");

  // Requester solo ve sus propios tickets.
  if (
    auth.role === "REQUESTER" &&
    res.Item.requesterId !== auth.sub
  ) {
    return forbidden();
  }
  return ok(res.Item);
}

async function listTickets(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
  auth: ReturnType<typeof getAuth>
) {
  if (!auth) return unauthorized();
  const qs = event.queryStringParameters ?? {};
  const limit = Math.min(Number(qs.limit ?? 25), 100);
  let result;

  if (auth.role === "REQUESTER") {
    // Tickets creados por el requester (GSI2)
    result = await ddb.send(
      new QueryCommand({
        TableName: MAIN_TABLE,
        IndexName: "GSI2",
        KeyConditionExpression: "GSI2PK = :pk AND begins_with(GSI2SK, :sk)",
        ExpressionAttributeValues: {
          ":pk": `REQUESTER#${auth.sub}`,
          ":sk": "TICKET#",
        },
        ScanIndexForward: false,
        Limit: limit,
      })
    );
  } else if (auth.role === "AGENT") {
    // Tickets asignados al agente (GSI3); requiere ?state=
    const state = qs.state ?? "IN_PROGRESS";
    result = await ddb.send(
      new QueryCommand({
        TableName: MAIN_TABLE,
        IndexName: "GSI3",
        KeyConditionExpression: "GSI3PK = :pk AND begins_with(GSI3SK, :sk)",
        ExpressionAttributeValues: {
          ":pk": `ASSIGNED#${auth.sub}#${state}`,
          ":sk": "TICKET#",
        },
        ScanIndexForward: true,
        Limit: limit,
      })
    );
  } else {
    // Manager/Admin: todos los tickets de un area (GSI4)
    const areaId = qs.areaId ?? auth.areaId;
    if (!areaId) return badRequest("areaId requerido");
    const skPrefix = qs.state ? `TICKET#${qs.state}#` : "TICKET#";
    result = await ddb.send(
      new QueryCommand({
        TableName: MAIN_TABLE,
        IndexName: "GSI4",
        KeyConditionExpression: "GSI4PK = :pk AND begins_with(GSI4SK, :sk)",
        ExpressionAttributeValues: {
          ":pk": `AREA#${areaId}`,
          ":sk": skPrefix,
        },
        ScanIndexForward: false,
        Limit: limit,
      })
    );
  }

  return ok({
    items: result.Items ?? [],
    nextCursor: result.LastEvaluatedKey ?? null,
  });
}

async function updateTicket(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
  auth: ReturnType<typeof getAuth>
) {
  if (!auth) return unauthorized();
  if (!hasRole(auth, "AGENT", "MANAGER", "ADMIN")) return forbidden();

  const id = event.pathParameters?.id;
  if (!id) return badRequest("id requerido");

  const body = JSON.parse(event.body ?? "{}");
  const { state, assignedToId, assignedToName, resolutionNotes } = body;

  if (state && !VALID_STATES.includes(state)) {
    return badRequest("state invalido");
  }

  const current = await ddb.send(
    new GetCommand({
      TableName: MAIN_TABLE,
      Key: { PK: `TICKET#${id}`, SK: `METADATA#${id}` },
    })
  );
  if (!current.Item) return notFound("Ticket no existe");

  const t = current.Item;
  const ts = now();
  const newState: TicketState = state ?? t.state;
  const newAssignee = assignedToId ?? t.assignedToId;
  const prio = t.priority;
  const areaId = t.areaId;

  const sets: string[] = [
    "#state = :state",
    "updatedAt = :ts",
    "GSI1PK = :g1pk",
    "GSI1SK = :g1sk",
    "GSI4SK = :g4sk",
  ];
  const values: Record<string, unknown> = {
    ":state": newState,
    ":ts": ts,
    ":g1pk": `AREA#${areaId}#${newState}`,
    ":g1sk": `TICKET#${prio}#${t.createdAt}`,
    ":g4sk": `TICKET#${newState}#${prio}#${t.createdAt}`,
  };

  if (assignedToId !== undefined) {
    sets.push("assignedToId = :aid", "assignedToName = :aname");
    sets.push("GSI3PK = :g3pk", "GSI3SK = :g3sk");
    values[":aid"] = assignedToId;
    values[":aname"] = assignedToName ?? null;
    values[":g3pk"] = `ASSIGNED#${newAssignee}#${newState}`;
    values[":g3sk"] = `TICKET#${prio}#${ts}`;
  }
  if (resolutionNotes !== undefined) {
    sets.push("resolutionNotes = :rn");
    values[":rn"] = resolutionNotes;
  }
  if (newState === "RESOLVED") {
    sets.push("resolvedAt = :ts");
  }
  if (newState === "CLOSED") {
    sets.push("closedAt = :ts");
  }

  const updated = await ddb.send(
    new UpdateCommand({
      TableName: MAIN_TABLE,
      Key: { PK: `TICKET#${id}`, SK: `METADATA#${id}` },
      UpdateExpression: `SET ${sets.join(", ")}`,
      ExpressionAttributeNames: { "#state": "state" },
      ExpressionAttributeValues: values,
      ReturnValues: "ALL_NEW",
    })
  );

  // Audit trail del cambio de estado
  if (state && state !== t.state) {
    await ddb.send(
      new PutCommand({
        TableName: MAIN_TABLE,
        Item: {
          PK: `TICKET#${id}`,
          SK: `STATUSCHANGE#${ts}#${newId()}`,
          entityType: "STATUSCHANGE",
          ticketId: id,
          fromState: t.state,
          toState: newState,
          changedBy: auth.sub,
          changedByName: auth.email,
          reason: body.reason ?? null,
          createdAt: ts,
        },
      })
    );
  }

  return ok(updated.Attributes);
}
