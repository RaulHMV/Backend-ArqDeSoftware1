export type Role = "REQUESTER" | "AGENT" | "MANAGER" | "ADMIN";

export type TicketState =
  | "NEW"
  | "ASSIGNED"
  | "IN_PROGRESS"
  | "RESOLVED"
  | "CLOSED";

export type Priority = "LOW" | "MEDIUM" | "HIGH" | "CRITICAL";

export interface AuthContext {
  sub: string;
  email: string;
  groups: string[];
  role: Role;
  areaId: string | null;
}

export interface TicketInput {
  title: string;
  description: string;
  category: string;
  priority: Priority;
  areaId: string;
}
