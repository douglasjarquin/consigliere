const env = import.meta.env;
const rawBase = (env && env.BASE_URL) || "/consigliere/";
const baseUrl = `${rawBase.replace(/\/+$/, "")}/`;

export function sitePath(relativePath = "") {
  const cleanPath = relativePath.replace(/^\/+|\/+$/g, "");
  return cleanPath.length === 0 ? baseUrl : `${baseUrl}${cleanPath}/`;
}
