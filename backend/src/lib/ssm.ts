import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";

const region = process.env.APP_REGION ?? process.env.AWS_REGION;
const client = new SSMClient({ region });
const cache = new Map<string, string>();

/** Lee un parametro de SSM con cache en memoria (vive mientras la Lambda este caliente). */
export async function getParam(name: string): Promise<string> {
  const cached = cache.get(name);
  if (cached) return cached;

  const res = await client.send(new GetParameterCommand({ Name: name }));
  const value = res.Parameter?.Value ?? "";
  if (value) cache.set(name, value);
  return value;
}
