import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";

const region = process.env.APP_REGION ?? process.env.AWS_REGION;

export const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }), {
  marshallOptions: { removeUndefinedValues: true },
});

export const MAIN_TABLE = process.env.MAIN_TABLE as string;
export const WS_TABLE = process.env.WS_TABLE as string;
