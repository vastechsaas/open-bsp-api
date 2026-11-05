export function hasInternalServiceAuth(
  request: Request,
  edgeToken: string | undefined,
  serviceRoleKey: string | undefined,
): boolean {
  const authorization = request.headers.get("Authorization");
  return [edgeToken, serviceRoleKey].some(
    (credential) => !!credential && authorization === `Bearer ${credential}`,
  );
}
