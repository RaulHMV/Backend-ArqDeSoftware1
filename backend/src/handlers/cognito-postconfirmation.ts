import type { PostConfirmationTriggerEvent } from "aws-lambda";
import { PutCommand } from "@aws-sdk/lib-dynamodb";
import {
  CognitoIdentityProviderClient,
  AdminAddUserToGroupCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import { ddb, MAIN_TABLE } from "../lib/ddb.js";
import { now } from "../lib/ids.js";

const region = process.env.APP_REGION ?? process.env.AWS_REGION;
const cognito = new CognitoIdentityProviderClient({ region });

/**
 * Trigger PostConfirmation: al confirmar el registro crea el item USER en
 * DynamoDB y agrega al usuario al grupo Requester por defecto.
 */
export const handler = async (
  event: PostConfirmationTriggerEvent
): Promise<PostConfirmationTriggerEvent> => {
  if (event.triggerSource !== "PostConfirmation_ConfirmSignUp") {
    return event;
  }

  const sub = event.request.userAttributes.sub;
  const email = event.request.userAttributes.email;
  const ts = now();

  await ddb.send(
    new PutCommand({
      TableName: MAIN_TABLE,
      Item: {
        PK: `USER#${sub}`,
        SK: `PROFILE#${sub}`,
        entityType: "USER",
        userId: sub,
        email,
        fullName: email,
        role: "REQUESTER",
        areaId: null,
        isActive: true,
        createdAt: ts,
        updatedAt: ts,
        GSI4PK: "AREA#UNASSIGNED",
        GSI4SK: `USER#REQUESTER#${sub}`,
      },
      ConditionExpression: "attribute_not_exists(PK)",
    })
  ).catch((err) => {
    // Si ya existe, no es un error fatal para el flujo de signup.
    if (err?.name !== "ConditionalCheckFailedException") throw err;
  });

  await cognito.send(
    new AdminAddUserToGroupCommand({
      UserPoolId: event.userPoolId,
      Username: event.userName,
      GroupName: "Requester",
    })
  );

  return event;
};
