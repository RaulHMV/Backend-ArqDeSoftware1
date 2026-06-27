import type {
  APIGatewayRequestAuthorizerEvent,
  APIGatewayAuthorizerResult,
} from "aws-lambda";
import { CognitoJwtVerifier } from "aws-jwt-verify";

const verifier = CognitoJwtVerifier.create({
  userPoolId: process.env.COGNITO_POOL_ID as string,
  tokenUse: "id",
  clientId: process.env.COGNITO_CLIENT_ID as string,
});

function policy(
  principalId: string,
  effect: "Allow" | "Deny",
  resource: string,
  context: Record<string, string> = {}
): APIGatewayAuthorizerResult {
  return {
    principalId,
    policyDocument: {
      Version: "2012-10-17",
      Statement: [
        { Action: "execute-api:Invoke", Effect: effect, Resource: resource },
      ],
    },
    context,
  };
}

/** Lambda Authorizer (REQUEST) del $connect: valida el JWT del query string. */
export const handler = async (
  event: APIGatewayRequestAuthorizerEvent
): Promise<APIGatewayAuthorizerResult> => {
  const token = event.queryStringParameters?.token;
  const resource = event.methodArn;

  if (!token) return policy("anonymous", "Deny", resource);

  try {
    const payload = await verifier.verify(token);
    const groups = (payload["cognito:groups"] as string[] | undefined) ?? [];
    return policy(String(payload.sub), "Allow", resource, {
      userId: String(payload.sub),
      email: String(payload.email ?? ""),
      areaId: String(payload["custom:areaId"] ?? ""),
      groups: Array.isArray(groups) ? groups.join(",") : String(groups),
    });
  } catch (err) {
    console.warn("ws-authorizer rejected token", err);
    return policy("anonymous", "Deny", resource);
  }
};
