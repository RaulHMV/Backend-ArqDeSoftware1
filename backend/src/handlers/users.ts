import type {
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import { GetCommand, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import {
  CognitoIdentityProviderClient,
  AdminAddUserToGroupCommand,
  AdminUpdateUserAttributesCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import { ddb, MAIN_TABLE } from "../lib/ddb.js";
import { getAuth, hasRole } from "../lib/auth.js";
import { now } from "../lib/ids.js";
import {
  ok,
  created,
  badRequest,
  unauthorized,
  forbidden,
  notFound,
  serverError,
} from "../lib/response.js";

const region = process.env.APP_REGION ?? process.env.AWS_REGION;
const cognito = new CognitoIdentityProviderClient({ region });
const POOL_ID = process.env.COGNITO_POOL_ID as string;

export const handler = async (
  event: APIGatewayProxyEventV2WithJWTAuthorizer
): Promise<APIGatewayProxyResultV2> => {
  const auth = getAuth(event);
  if (!auth) return unauthorized();

  try {
    switch (event.routeKey) {
      case "GET /users/me": {
        const res = await ddb.send(
          new GetCommand({
            TableName: MAIN_TABLE,
            Key: { PK: `USER#${auth.sub}`, SK: `PROFILE#${auth.sub}` },
          })
        );
        return ok(res.Item ?? { userId: auth.sub, email: auth.email, role: auth.role });
      }

      case "GET /users": {
        if (!hasRole(auth, "MANAGER", "ADMIN")) return forbidden();
        const areaId = event.queryStringParameters?.areaId ?? auth.areaId;
        if (!areaId) return badRequest("areaId requerido");
        const res = await ddb.send(
          new QueryCommand({
            TableName: MAIN_TABLE,
            IndexName: "GSI4",
            KeyConditionExpression: "GSI4PK = :pk AND begins_with(GSI4SK, :sk)",
            ExpressionAttributeValues: {
              ":pk": `AREA#${areaId}`,
              ":sk": "USER#",
            },
          })
        );
        return ok({ items: res.Items ?? [] });
      }

      case "POST /users": {
        if (!hasRole(auth, "ADMIN")) return forbidden();
        return await upsertUser(event);
      }

      default:
        return notFound("Route not handled");
    }
  } catch (err) {
    console.error("users handler error", err);
    return serverError();
  }
};

async function upsertUser(event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  const body = JSON.parse(event.body ?? "{}");
  const { userId, email, fullName, role, areaId } = body;
  if (!userId || !email || !role) {
    return badRequest("userId, email y role son obligatorios");
  }

  const ts = now();
  const item = {
    PK: `USER#${userId}`,
    SK: `PROFILE#${userId}`,
    entityType: "USER",
    userId,
    email,
    fullName: fullName ?? email,
    role,
    areaId: areaId ?? null,
    isActive: true,
    createdAt: ts,
    updatedAt: ts,
    GSI4PK: areaId ? `AREA#${areaId}` : "AREA#UNASSIGNED",
    GSI4SK: `USER#${role}#${userId}`,
  };

  await ddb.send(new PutCommand({ TableName: MAIN_TABLE, Item: item }));

  // Sincroniza rol (grupo) y area (custom:areaId) en Cognito.
  await cognito.send(
    new AdminAddUserToGroupCommand({
      UserPoolId: POOL_ID,
      Username: email,
      GroupName: role.charAt(0) + role.slice(1).toLowerCase(),
    })
  );
  if (areaId) {
    await cognito.send(
      new AdminUpdateUserAttributesCommand({
        UserPoolId: POOL_ID,
        Username: email,
        UserAttributes: [{ Name: "custom:areaId", Value: areaId }],
      })
    );
  }

  return created(item);
}
