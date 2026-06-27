import type {
  APIGatewayProxyWebsocketEventV2,
  APIGatewayProxyResultV2,
} from "aws-lambda";
import { DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, WS_TABLE } from "../lib/ddb.js";

export const handler = async (
  event: APIGatewayProxyWebsocketEventV2
): Promise<APIGatewayProxyResultV2> => {
  const connectionId = event.requestContext.connectionId;
  await ddb.send(
    new DeleteCommand({ TableName: WS_TABLE, Key: { connectionId } })
  );
  return { statusCode: 200, body: "Disconnected" };
};
